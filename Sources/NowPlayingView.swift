import SwiftUI
import AppKit

/// Live level readout for the Now Playing view.
struct NowPlayingStats: Equatable {
    var active = false
    var source = -160.0
    var gain = 0.0
    var target = -16.0
    var known = false
    var learned = 0
    var output = "\u{2014}"
    var battery: OutputBattery.Status = .unavailable   // wireless output charge
    var plays = 0
    var love: Double?
    var audioPresent = false
}

/// Tracks the currently-playing track (metadata + artwork), whether it's
/// playing or paused, and Ballast's live stats for the Now Playing mode.
/// Metadata refreshes on the engine's track-change notifications; stats + the
/// idle-gradient phase are driven by a timer (an ObservableObject re-renders
/// reliably where a hosted TimelineView did not).
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published var artwork: NSImage?
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var hasTrack = false
    @Published var isPlaying = false
    @Published var stats = NowPlayingStats()
    @Published var phase: Double = 0
    @Published var palette: [SIMD3<Float>]?
    @Published var elapsed: Double = 0     // interpolated playhead, seconds
    @Published var duration: Double = 0    // current track length, seconds

    weak var engine: BallastEngine?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    // Playhead interpolation: sample the player occasionally, then advance the
    // playhead locally each tick so the progress bar is smooth without polling
    // AppleScript at the timer's rate.
    private var baseElapsed: Double = 0
    private var baseAt: Double = 0
    private var lastPositionResync: Double = 0
    private static let positionResyncInterval: Double = 5.0

    // Output-device battery: slow-moving, so poll rarely (and immediately when
    // the output device changes). Resolved off-main; system_profiler is only
    // spawned when the output is Bluetooth.
    private var batteryStatus: OutputBattery.Status = .unavailable
    private var lastBatteryPoll: Double = 0
    private var lastOutputName = ""
    private static let batteryPollInterval: Double = 60.0

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        if observers.isEmpty {
            let center = DistributedNotificationCenter.default()
            for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
                observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                    self?.applyNotification(note)
                })
            }
        }
        if timer == nil {
            let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        refreshOnOpen()
        refreshStats()
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        timer?.invalidate(); timer = nil
    }

    private func tick() {
        if !hasTrack { phase += 0.08 }        // drift only while the gradient shows
        advancePlayhead()
        pollBatteryIfDue()
        refreshStats()
    }

    /// Probe the player once and reflect whatever comes back (clearing to the
    /// idle state on nothing). The fallback when a notification arrives without a
    /// track name — a pause/stop, where the player isn't lagging.
    func refresh() { probeCurrent(retryIfEmpty: false, attemptsLeft: 0) }

    /// Probe on window-open. Here we don't yet know which track to expect, so if
    /// the one-shot probe comes back empty *while audio is actually playing*,
    /// retry briefly (bounded) — otherwise opening the visualiser mid-track
    /// strands it on the metadata-less "Playing" screen until the next track
    /// change, even though a track is plainly playing.
    private func refreshOnOpen() { probeCurrent(retryIfEmpty: true, attemptsLeft: Self.openProbeAttempts) }

    private func probeCurrent(retryIfEmpty: Bool, attemptsLeft: Int) {
        NowPlayingProbe.nowPlaying { [weak self] info in
            guard let self else { return }
            if let info {
                self.artwork = info.artwork
                self.title = info.title
                self.artist = info.artist
                self.album = info.album
                self.hasTrack = true
                self.isPlaying = info.isPlaying
                self.syncPlayhead(elapsed: info.elapsed, duration: info.duration)
                return
            }
            // Nothing came back. If audio is playing, the player just didn't
            // answer this probe in time — try again shortly. A notification
            // arriving meanwhile (hasTrack) supersedes us, and a browser (audio
            // but no scriptable track) simply falls through to the "Playing"
            // screen once the attempts are spent.
            if retryIfEmpty, attemptsLeft > 1, !self.hasTrack, self.engine?.hasAudioSignal == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.metadataRetryDelay) { [weak self] in
                    self?.probeCurrent(retryIfEmpty: true, attemptsLeft: attemptsLeft - 1)
                }
                return
            }
            if !retryIfEmpty {
                self.artwork = nil; self.title = ""; self.artist = ""; self.album = ""
                self.hasTrack = false; self.isPlaying = false
                self.duration = 0; self.elapsed = 0
            }
        }
    }

    // How many times to re-probe for artwork/playhead while the player's
    // scripting dictionary catches up to the notification, and how long between.
    private static let metadataMatchAttempts = 6
    private static let metadataRetryDelay = 0.35
    // How many times the window-open probe retries while audio is playing but
    // the player hasn't answered yet (same cadence as the track-change retry).
    private static let openProbeAttempts = 6

    /// Handle a track-change notification. The notification's `userInfo` carries
    /// the authoritative title/artist/album, so text updates *immediately* —
    /// whereas the player's AppleScript `current track` lags a boundary by up to
    /// a second, which is what made the visualiser paint the outgoing track.
    /// Artwork and the playhead still come from AppleScript, but only once a
    /// probe agrees on the track (validated, with a short bounded retry).
    private func applyNotification(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let state = (info["Player State"] as? String) ?? ""
        let playing = state.isEmpty || state.caseInsensitiveCompare("Playing") == .orderedSame
        let name = (info["Name"] as? String) ?? ""

        // Paused/stopped, or a notification without a track name (some sources):
        // a full probe is correct here — the player isn't lagging on a pause.
        guard playing, !name.isEmpty else { refresh(); return }

        let newArtist = (info["Artist"] as? String) ?? ""
        let newAlbum = (info["Album"] as? String) ?? ""
        let changed = name.caseInsensitiveCompare(title) != .orderedSame
            || newArtist.caseInsensitiveCompare(artist) != .orderedSame
        title = name
        artist = newArtist
        album = newAlbum
        hasTrack = true
        isPlaying = true
        // Drop the outgoing track's artwork/progress at once so nothing stale
        // lingers under the new title while the validated probe catches up.
        if changed { artwork = nil; elapsed = 0; duration = 0 }
        fetchArtworkAndPlayhead(matching: name, attemptsLeft: Self.metadataMatchAttempts)
    }

    /// Fetch artwork + playhead, accepting them only once the player reports the
    /// track we're expecting; otherwise retry briefly (bounded) so a boundary
    /// lag can't leave the outgoing track's cover under the new title.
    private func fetchArtworkAndPlayhead(matching expected: String, attemptsLeft: Int) {
        NowPlayingProbe.nowPlaying { [weak self] info in
            guard let self else { return }
            // Abandon quietly if another track change superseded this one.
            guard self.title.caseInsensitiveCompare(expected) == .orderedSame else { return }
            if let info, info.title.caseInsensitiveCompare(expected) == .orderedSame {
                self.artwork = info.artwork
                if !info.album.isEmpty { self.album = info.album }
                self.isPlaying = info.isPlaying
                self.syncPlayhead(elapsed: info.elapsed, duration: info.duration)
            } else if attemptsLeft > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.metadataRetryDelay) { [weak self] in
                    self?.fetchArtworkAndPlayhead(matching: expected, attemptsLeft: attemptsLeft - 1)
                }
            }
        }
    }

    // MARK: Playhead

    /// Anchor the interpolated playhead to a fresh reading from the player.
    private func syncPlayhead(elapsed: Double, duration: Double) {
        baseElapsed = elapsed
        baseAt = now
        lastPositionResync = now
        self.duration = duration
        self.elapsed = max(0, min(duration > 0 ? duration : elapsed, elapsed))
    }

    /// Advance the playhead locally each tick, and re-sync from the player
    /// every few seconds to absorb scrubs and clock drift.
    private func advancePlayhead() {
        guard hasTrack, duration > 0 else { return }
        let e = isPlaying ? baseElapsed + (now - baseAt) : baseElapsed
        elapsed = max(0, min(duration, e))
        if now - lastPositionResync > Self.positionResyncInterval {
            lastPositionResync = now
            NowPlayingProbe.playback { [weak self] p in
                guard let self, let p else { return }
                self.isPlaying = p.isPlaying
                self.syncPlayhead(elapsed: p.elapsed, duration: p.duration)
            }
        }
    }

    // MARK: Battery

    private func pollBatteryIfDue() {
        guard now - lastBatteryPoll > Self.batteryPollInterval else { return }
        lastBatteryPoll = now
        let deviceAtPoll = lastOutputName
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = OutputBattery.currentOutputStatus()
            DispatchQueue.main.async {
                guard let self, self.lastOutputName == deviceAtPoll else { return }
                switch status {
                case .level:
                    self.batteryStatus = status          // a fresh reading always wins
                case .unknown:
                    // Sticky: Bluetooth headphones advertise their battery only
                    // intermittently. Keep a last-known level rather than
                    // downgrading to "tbc" on a momentarily empty poll; only
                    // show "tbc" if we've never had a level for this device.
                    if case .level = self.batteryStatus { break }
                    self.batteryStatus = .unknown
                case .unavailable:
                    self.batteryStatus = .unavailable    // wired/built-in — no row
                }
            }
        }
    }

    func refreshStats() {
        guard let e = engine else { return }
        let outputName = e.currentOutputDeviceName ?? "\u{2014}"
        // Re-poll battery straight away when the output device changes, rather
        // than waiting out the interval on a device we know nothing about yet.
        if outputName != lastOutputName {
            lastOutputName = outputName
            lastBatteryPoll = 0
            batteryStatus = .unavailable
        }
        let next = NowPlayingStats(
            active: e.isActive,
            source: Double(e.processor.meterSourceLoudness),
            gain: Double(e.processor.meterGainDB),
            target: BallastSettings.targetLoudness,
            known: e.currentTrackKnown,
            learned: e.libraryCount,
            output: outputName,
            battery: batteryStatus,
            plays: e.currentTrackPlays,
            love: e.currentTrackLove,
            audioPresent: e.hasAudioSignal
        )
        if next != stats { stats = next }
    }
}

/// The Now Playing mode. States: a held (dimmed) card when paused, the full
/// card when playing a known source, a "Playing" readout for metadata-less
/// audio (a browser), a "Levelling is off" note, or — when simply stopped — a
/// slow wallpaper-tinted drifting gradient and nothing else.
struct NowPlayingView: View {
    @ObservedObject var model: NowPlayingModel

    private enum Screen { case off, track, playing, idle }
    private var screen: Screen {
        if !model.stats.active { return .off }
        if model.hasTrack { return .track }
        if model.stats.audioPresent { return .playing }
        return .idle
    }
    private var live: Bool { model.stats.active && (model.isPlaying || model.stats.audioPresent) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let s = min(w, h)
            ZStack {
                backdrop(s)
                switch screen {
                case .track:
                    trackContent(w: w, h: h, s: s).padding(s * 0.06).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .playing:
                    playingContent(s).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .off:
                    Text("Levelling is off").font(.system(size: s * 0.07, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .idle:
                    EmptyView()
                }
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .ignoresSafeArea()
    }

    // MARK: Backdrop

    @ViewBuilder private func backdrop(_ s: CGFloat) -> some View {
        if screen == .track, let art = model.artwork {
            Image(nsImage: art).resizable().scaledToFill()
                .blur(radius: s * 0.12).overlay(Color.black.opacity(model.isPlaying ? 0.5 : 0.62))
        } else {
            driftingGradient()
        }
    }

    private func driftingGradient() -> some View {
        let cols = gradientColors()
        let a = model.phase * 0.15
        let start = UnitPoint(x: 0.5 + 0.45 * cos(a), y: 0.5 + 0.45 * sin(a * 0.8))
        let end = UnitPoint(x: 0.5 - 0.45 * cos(a * 1.1), y: 0.5 - 0.45 * sin(a))
        return LinearGradient(colors: cols, startPoint: start, endPoint: end)
    }

    private func gradientColors() -> [Color] {
        if let p = model.palette, p.count >= 3 {
            return [tint(p[0], 0.5), tint(p[1], 0.32), tint(p[2], 0.55)]
        }
        return [Color(red: 0.10, green: 0.11, blue: 0.14),
                Color(red: 0.05, green: 0.06, blue: 0.10),
                Color(red: 0.09, green: 0.10, blue: 0.13)]
    }

    private func tint(_ c: SIMD3<Float>, _ scale: Double) -> Color {
        Color(.sRGB, red: Double(c.x) * scale, green: Double(c.y) * scale, blue: Double(c.z) * scale, opacity: 1)
    }

    // MARK: Track (playing or paused)

    @ViewBuilder private func trackContent(w: CGFloat, h: CGFloat, s: CGFloat) -> some View {
        let paused = !model.isPlaying
        let landscape = w > h * 1.25
        let side = landscape ? min(h * 0.72, w * 0.4) : min(h * 0.45, w * 0.72)
        let artColumn = VStack(spacing: s * 0.028) {
            loveLine(model.stats, s).frame(width: side)   // hearts + plays above the art
            art(side, paused: paused)
            progressBar(s, width: side)                    // time bar tucked under the art
        }
        if landscape {
            HStack(spacing: s * 0.06) { artColumn; details(s, paused: paused) }
        } else {
            VStack(spacing: s * 0.04) { artColumn; details(s, paused: paused) }
        }
    }

    private func art(_ side: CGFloat, paused: Bool) -> some View {
        Group {
            if let a = model.artwork {
                Image(nsImage: a).resizable().scaledToFill()
            } else {
                ZStack { Color(white: 0.18); Image(systemName: "music.note").font(.system(size: side * 0.3)).foregroundStyle(.white.opacity(0.35)) }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.06, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: side * 0.05, y: side * 0.02)
        .opacity(paused ? 0.72 : 1)
        .overlay { if paused { pauseBadge(side) } }
    }

    /// A pause glyph centred on the artwork while paused. A translucent dark
    /// disc keeps the white bars legible over light covers; the soft shadow
    /// keeps them legible over dark ones — contrast either way.
    private func pauseBadge(_ side: CGFloat) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.5)).frame(width: side * 0.32, height: side * 0.32)
            Image(systemName: "pause.fill")
                .font(.system(size: side * 0.16, weight: .semibold))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.45), radius: side * 0.03)
    }

    /// The metadata + stats column. The hero title/artist/album always render
    /// at full size; only the stats panel scales down to fit the height left
    /// below the header — a Known track (Length, Battery, full stats) is taller
    /// than a still-learning one, and because every size derives from
    /// `min(width, height)` a bigger window scales content up too, so the panel
    /// alone absorbs any overflow rather than shrinking the title with it.
    private func details(_ s: CGFloat, paused: Bool) -> some View {
        GeometryReader { geo in
            DetailsColumn(
                available: geo.size.height,
                spacing: s * 0.026,
                statsTopPad: s * 0.03,
                header: { headerBlock(s) },
                stats: { statsPanel(model.stats, s, includeThisTrack: true) }
            )
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .opacity(paused ? 0.85 : 1)
        }
    }

    @ViewBuilder private func headerBlock(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: s * 0.026) {
            Text(model.title).font(.system(size: s * 0.088, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(.white)
            Text(model.artist).font(.system(size: s * 0.058))
                .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white.opacity(0.85))
            if !model.album.isEmpty {
                Text(model.album).font(.system(size: s * 0.046))
                    .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder private func loveLine(_ st: NowPlayingStats, _ s: CGFloat) -> some View {
        if st.plays > 0 {
            HStack(spacing: s * 0.016) {
                ForEach(0..<5) { i in
                    Image(systemName: i < heartCount(st.love) ? "heart.fill" : "heart")
                        .font(.system(size: s * 0.04)).foregroundStyle(Color(red: 0.96, green: 0.36, blue: 0.46))
                }
                Text(st.plays == 1 ? "1 play" : "\(st.plays) plays")
                    .font(.system(size: s * 0.044)).foregroundStyle(.white.opacity(0.75)).padding(.leading, s * 0.02)
            }
            .padding(.top, s * 0.008)
        }
    }

    private func heartCount(_ love: Double?) -> Int {
        guard let love else { return 1 }
        return min(5, max(1, Int((love * 4).rounded()) + 1))
    }

    // MARK: Progress (elapsed / remaining)

    @ViewBuilder private func progressBar(_ s: CGFloat, width: CGFloat) -> some View {
        if model.duration > 0 {
            // Derive both labels from the SAME whole-second elapsed value so
            // they tick together: rounding elapsed and (duration - elapsed)
            // independently makes them flip at different fractional instants.
            let total = Int(model.duration.rounded())
            let elapsed = max(0, min(total, Int(model.elapsed)))
            let remaining = total - elapsed
            let frac = min(1, max(0, model.elapsed / model.duration))
            let barH = s * 0.014
            VStack(spacing: s * 0.016) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(.white.opacity(0.92)).frame(width: g.size.width * frac)
                    }
                }
                .frame(height: barH)
                HStack(spacing: 0) {
                    Text(timeString(elapsed))
                    Spacer(minLength: 0)
                    Text("-" + timeString(remaining))
                }
                .font(.system(size: s * 0.036, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: width)
        }
    }

    private func timeString(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // MARK: Playing (metadata-less audio, e.g. a browser)

    private func playingContent(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: s * 0.03) {
            Text("Playing").font(.system(size: s * 0.09, weight: .bold)).foregroundStyle(.white)
            statsPanel(model.stats, s, includeThisTrack: false)
        }
        .padding(s * 0.06)
    }

    // MARK: Stats panel

    private func statsPanel(_ st: NowPlayingStats, _ s: CGFloat, includeThisTrack: Bool) -> some View {
        VStack(spacing: s * 0.015) {
            statRow("Source", live && st.source > -100 ? String(format: "%.1f LUFS", st.source) : "\u{2014}", s)
            statRow("Adjustment", live ? String(format: "%+.1f dB", st.gain) : "\u{2014}", s)
            statRow("Target", String(format: "%.0f LUFS", st.target), s)
            if includeThisTrack {
                statRow("This track", st.known ? "Known \u{2014} fixed level" : "Learning\u{2026}", s)
                if model.duration > 0 {
                    statRow("Length", timeString(Int(model.duration.rounded())), s)
                }
            }
            statRow("Learned", "\(st.learned) tracks", s)
            statRow("Output", st.output, s)
            switch st.battery {
            case .level(let pct):        batteryRow(pct, s)   // only when a real level is reported
            case .unknown, .unavailable: EmptyView()
            }
        }
        .padding(s * 0.036)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: s * 0.03, style: .continuous))
        .frame(maxWidth: s * 1.15, alignment: .leading)
    }

    private func statRow(_ label: String, _ value: String, _ s: CGFloat) -> some View {
        HStack(spacing: s * 0.04) {
            Text(label).font(.system(size: s * 0.042)).foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
            Text(value).font(.system(size: s * 0.042, design: .rounded)).monospacedDigit().lineLimit(1).foregroundStyle(.white)
        }
    }

    private func batteryRow(_ level: Int, _ s: CGFloat) -> some View {
        HStack(spacing: s * 0.04) {
            Text("Battery").font(.system(size: s * 0.042)).foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
            HStack(spacing: s * 0.018) {
                Image(systemName: batterySymbol(level)).font(.system(size: s * 0.042))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(batteryColor(level))
                Text("\(level)%").font(.system(size: s * 0.042, design: .rounded)).monospacedDigit().foregroundStyle(.white)
            }
        }
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13:  return "battery.0percent"
        case ..<38:  return "battery.25percent"
        case ..<63:  return "battery.50percent"
        case ..<88:  return "battery.75percent"
        default:     return "battery.100percent"
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        switch level {
        case ..<15: return Color(red: 0.95, green: 0.35, blue: 0.35)
        case ..<30: return Color(red: 0.98, green: 0.72, blue: 0.30)
        default:    return .white
        }
    }
}

private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct StatsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Stacks a full-size `header` above a `stats` panel, and scales ONLY the stats
/// down (never up) so the pair fits within `available` height. The header keeps
/// its natural size; the stats absorb any overflow. Both heights are measured,
/// so the stats are given exactly the space left below the header.
private struct DetailsColumn<Header: View, Stats: View>: View {
    let available: CGFloat
    let spacing: CGFloat
    let statsTopPad: CGFloat
    @ViewBuilder var header: Header
    @ViewBuilder var stats: Stats

    @State private var headerHeight: CGFloat = 0
    @State private var statsHeight: CGFloat = 0

    var body: some View {
        let room = max(0, available - headerHeight - statsTopPad)
        let scale = (statsHeight > room && room > 0) ? room / statsHeight : 1
        VStack(alignment: .leading, spacing: spacing) {
            header
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeaderHeightKey.self, value: g.size.height)
                })
            stats
                .background(GeometryReader { g in
                    Color.clear.preference(key: StatsHeightKey.self, value: g.size.height)
                })
                .scaleEffect(scale, anchor: .topLeading)
                .frame(height: statsHeight > 0 ? min(statsHeight, room) : nil, alignment: .topLeading)
                .padding(.top, statsTopPad)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
        .onPreferenceChange(StatsHeightKey.self) { statsHeight = $0 }
    }
}
