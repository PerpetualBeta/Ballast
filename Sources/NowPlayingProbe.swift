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
}
