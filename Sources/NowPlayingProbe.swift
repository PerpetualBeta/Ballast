import AppKit

/// One-shot query of the *currently playing* track from Apple Music / Spotify,
/// via AppleScript. Used at startup so Ballast can apply a track's learned
/// level immediately, instead of waiting for the next track-change
/// notification. Only queries apps that are already running (never launches
/// one), and runs off the main thread so the first-time Automation permission
/// prompt can't freeze the menu bar.
enum NowPlayingProbe {

    enum Source { case music, spotify }

    struct Result {
        let source: Source
        let trackID: String     // Music: persistent-ID hex; Spotify: track URI
        let title: String
        let artist: String
        let durationMS: Int
    }

    static func query(_ completion: @escaping (Result?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = probeRunning()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func probeRunning() -> Result? {
        if isRunning("com.apple.Music"), let r = probe(app: "Music", source: .music) { return r }
        if isRunning("com.spotify.client"), let r = probe(app: "Spotify", source: .spotify) { return r }
        return nil
    }

    private static func probe(app: String, source: Source) -> Result? {
        // `id of t` is the Spotify track URI; `persistent ID of t` is Music's
        // hex ID. Fields joined by U+001F (never present in metadata).
        let idProp = source == .spotify ? "id" : "persistent ID"
        let script = """
        tell application "\(app)"
            if player state is playing then
                set sep to character id 31
                set t to current track
                return (\(idProp) of t) & sep & (name of t) & sep & (artist of t) & sep & ((duration of t) as text)
            end if
            return ""
        end tell
        """
        guard let fields = run(script), fields.count == 4 else { return nil }
        // Music duration is seconds; Spotify duration is milliseconds.
        let durationMS = source == .spotify
            ? (Int(fields[3]) ?? 0)
            : Int(((Double(fields[3]) ?? 0) * 1000).rounded())
        return Result(source: source, trackID: fields[0], title: fields[1], artist: fields[2], durationMS: durationMS)
    }

    private static func run(_ source: String) -> [String]? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        guard error == nil, let value = output.stringValue, !value.isEmpty else { return nil }
        return value.components(separatedBy: "\u{1F}")
    }

    // MARK: Now-playing info (title / artist / album / artwork) for the visualiser

    struct NowPlayingInfo {
        let title: String
        let artist: String
        let album: String
        let artwork: NSImage?
        let isPlaying: Bool      // false = paused (a current track exists but is held)
        let elapsed: Double      // playhead position, seconds
        let duration: Double     // track length, seconds (0 = unknown, e.g. a stream)
    }

    /// A cheap playhead reading (no metadata, no artwork) used to re-sync the
    /// locally interpolated progress between the heavier `nowPlaying` queries —
    /// so a manual scrub or drift is caught without re-fetching artwork.
    struct Playback {
        let elapsed: Double
        let duration: Double
        let isPlaying: Bool
    }

    static func nowPlaying(_ completion: @escaping (NowPlayingInfo?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let info = probeNowPlayingInfo()
            DispatchQueue.main.async { completion(info) }
        }
    }

    private static func probeNowPlayingInfo() -> NowPlayingInfo? {
        if isRunning("com.apple.Music"), let i = musicNowPlaying() { return i }
        if isRunning("com.spotify.client"), let i = spotifyNowPlaying() { return i }
        return nil
    }

    private static func musicNowPlaying() -> NowPlayingInfo? {
        let script = """
        tell application "Music"
            set sep to character id 31
            if player state is playing then
                set t to current track
                return "playing" & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((player position) as text) & sep & ((duration of t) as text)
            else if player state is paused then
                set t to current track
                return "paused" & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((player position) as text) & sep & ((duration of t) as text)
            end if
            return ""
        end tell
        """
        guard let f = run(script), f.count == 6 else { return nil }
        // Local artwork first. Apple Music *cloud* tracks (played from a playlist
        // but not added to the library) expose no artwork through scripting at
        // all, so fall back to a public cover lookup — the same "fetch a cover
        // over the network" path Spotify art already takes.
        let art = musicArtwork() ?? cloudArtwork(title: f[1], artist: f[2], album: f[3])
        // Music reports both player position and track duration in seconds.
        return NowPlayingInfo(title: f[1], artist: f[2], album: f[3], artwork: art,
                              isPlaying: f[0] == "playing",
                              elapsed: Double(f[4]) ?? 0, duration: Double(f[5]) ?? 0)
    }

    private static func musicArtwork() -> NSImage? {
        let src = """
        tell application "Music" to get data of artwork 1 of current track
        """
        guard let script = NSAppleScript(source: src) else { return nil }
        var error: NSDictionary?
        let out = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let data = out.data
        return data.isEmpty ? nil : NSImage(data: data)
    }

    // MARK: Cloud-track artwork fallback (iTunes Search API)

    // Streaming Apple Music tracks carry no scriptable artwork, so their cover
    // is looked up from Apple's public Search API by artist + title and fetched
    // over the network. Held to a single entry (the current track) and cached
    // even when the lookup finds nothing, so a probe every few seconds never
    // re-hits the network for the same track.
    private static let searchResultLimit = 5
    private static let searchTimeout: TimeInterval = 4
    private static let imageTimeout: TimeInterval = 6
    private static let cloudArtworkSize = 600            // upscaled from the 100×100 thumbnail

    private static let cloudArtLock = NSLock()
    private static var cloudArtKey: String?
    private static var cloudArtImage: NSImage?

    private static func cloudArtwork(title: String, artist: String, album: String) -> NSImage? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let key = "\(title)\u{1F}\(artist)\u{1F}\(album)"

        cloudArtLock.lock()
        if cloudArtKey == key { let cached = cloudArtImage; cloudArtLock.unlock(); return cached }
        cloudArtLock.unlock()

        let image = searchArtwork(title: title, artist: artist, album: album)

        cloudArtLock.lock()
        cloudArtKey = key; cloudArtImage = image
        cloudArtLock.unlock()
        return image
    }

    private static func searchArtwork(title: String, artist: String, album: String) -> NSImage? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(searchResultLimit)),
        ]
        guard let url = comps?.url,
              let data = fetchData(url, timeout: searchTimeout),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]], !results.isEmpty else { return nil }
        // Prefer a result from the same album; otherwise the first (most
        // relevant) match — either way it's the right song's cover.
        let match = results.first {
            guard !album.isEmpty, let coll = $0["collectionName"] as? String else { return false }
            return coll.localizedCaseInsensitiveContains(album)
        } ?? results.first
        guard let thumb = match?["artworkUrl100"] as? String else { return nil }
        let full = thumb.replacingOccurrences(of: "100x100bb", with: "\(cloudArtworkSize)x\(cloudArtworkSize)bb")
        guard let artURL = URL(string: full), let bytes = fetchData(artURL, timeout: imageTimeout) else { return nil }
        return NSImage(data: bytes)
    }

    /// Synchronous, timeout-bounded GET. Safe because every caller already runs
    /// off the main thread (`nowPlaying`'s background queue).
    private static func fetchData(_ url: URL, timeout: TimeInterval) -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        var result: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { result = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return result
    }

    private static func spotifyNowPlaying() -> NowPlayingInfo? {
        let script = """
        tell application "Spotify"
            set sep to character id 31
            if player state is playing then
                set t to current track
                return "playing" & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (artwork url of t) & sep & ((player position) as text) & sep & ((duration of t) as text)
            else if player state is paused then
                set t to current track
                return "paused" & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (artwork url of t) & sep & ((player position) as text) & sep & ((duration of t) as text)
            end if
            return ""
        end tell
        """
        guard let f = run(script), f.count == 7 else { return nil }
        var art: NSImage?
        if let url = URL(string: f[4]), let d = try? Data(contentsOf: url) { art = NSImage(data: d) }
        // Spotify player position is seconds; track duration is milliseconds.
        return NowPlayingInfo(title: f[1], artist: f[2], album: f[3], artwork: art,
                              isPlaying: f[0] == "playing",
                              elapsed: Double(f[5]) ?? 0, duration: (Double(f[6]) ?? 0) / 1000)
    }

    // MARK: Lightweight playhead (position only) for progress re-sync

    static func playback(_ completion: @escaping (Playback?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = probePlayback()
            DispatchQueue.main.async { completion(p) }
        }
    }

    private static func probePlayback() -> Playback? {
        if isRunning("com.apple.Music"), let p = playbackFor(app: "Music", durationInMS: false) { return p }
        if isRunning("com.spotify.client"), let p = playbackFor(app: "Spotify", durationInMS: true) { return p }
        return nil
    }

    private static func playbackFor(app: String, durationInMS: Bool) -> Playback? {
        let script = """
        tell application "\(app)"
            set sep to character id 31
            if player state is playing then
                set t to current track
                return "playing" & sep & ((player position) as text) & sep & ((duration of t) as text)
            else if player state is paused then
                set t to current track
                return "paused" & sep & ((player position) as text) & sep & ((duration of t) as text)
            end if
            return ""
        end tell
        """
        guard let f = run(script), f.count == 3 else { return nil }
        let dur = (Double(f[2]) ?? 0) / (durationInMS ? 1000 : 1)
        return Playback(elapsed: Double(f[1]) ?? 0, duration: dur, isPlaying: f[0] == "playing")
    }
}
