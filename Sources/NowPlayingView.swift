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
    var battery: Int?          // output-device charge %, when it's a wireless device
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
    private var batteryLevel: Int?
    private var lastBatteryPoll: Double = 0
    private var lastOutputName = ""
    private static let batteryPollInterval: Double = 60.0

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        if observers.isEmpty {
            let center = DistributedNotificationCenter.default()
            for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
                observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    self?.refresh()
                })
            }
        }
        if timer == nil {
            let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        refresh()
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

    func refresh() {
        NowPlayingProbe.nowPlaying { [weak self] info in
            guard let self else { return }
            self.artwork = info?.artwork
            self.title = info?.title ?? ""
            self.artist = info?.artist ?? ""
            self.album = info?.album ?? ""
            self.hasTrack = (info != nil)
            self.isPlaying = info?.isPlaying ?? false
            if let info {
                self.syncPlayhead(elapsed: info.elapsed, duration: info.duration)
            } else {
                self.duration = 0; self.elapsed = 0
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let level = OutputBattery.currentOutputBattery()
            DispatchQueue.main.async { self?.batteryLevel = level }
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
            batteryLevel = nil
        }
        let next = NowPlayingStats(
            active: e.isActive,
            source: Double(e.processor.meterSourceLoudness),
            gain: Double(e.processor.meterGainDB),
            target: BallastSettings.targetLoudness,
            known: e.currentTrackKnown,
            learned: e.libraryCount,
            output: outputName,
            battery: batteryLevel,
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
    }

    /// The metadata + stats column. Wrapped so it scales down to fit the height
    /// it's given: a Known track (hearts, Length, Battery, full stats) is taller
    /// than a still-learning one, and because every size is derived from
    /// `min(width, height)` a bigger window scales the content up too — so
    /// without this the tall case overflows at every window size.
    private func details(_ s: CGFloat, paused: Bool) -> some View {
        GeometryReader { geo in
            detailsStack(s, paused: paused)
                .background(GeometryReader { g in
                    Color.clear.preference(key: DetailsHeightKey.self, value: g.size.height)
                })
                .modifier(FitHeight(available: geo.size.height))
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    private func detailsStack(_ s: CGFloat, paused: Bool) -> some View {
        let st = model.stats
        return VStack(alignment: .leading, spacing: s * 0.026) {
            if paused {
                Text("PAUSED").font(.system(size: s * 0.032, weight: .heavy)).tracking(1.5)
                    .padding(.horizontal, s * 0.03).padding(.vertical, s * 0.012)
                    .background(.white.opacity(0.16), in: Capsule()).foregroundStyle(.white.opacity(0.9))
            }
            Text(model.title).font(.system(size: s * 0.088, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(.white)
            Text(model.artist).font(.system(size: s * 0.058))
                .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white.opacity(0.85))
            if !model.album.isEmpty {
                Text(model.album).font(.system(size: s * 0.046))
                    .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white.opacity(0.6))
            }
            statsPanel(st, s, includeThisTrack: true).padding(.top, s * 0.03)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(paused ? 0.85 : 1)
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
            let frac = min(1, max(0, model.elapsed / model.duration))
            let remaining = max(0, model.duration - model.elapsed)
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
                    Text(timeString(model.elapsed))
                    Spacer(minLength: 0)
                    Text("-" + timeString(remaining))
                }
                .font(.system(size: s * 0.036, design: .rounded)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: width)
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
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
                    statRow("Length", timeString(model.duration), s)
                }
            }
            statRow("Learned", "\(st.learned) tracks", s)
            statRow("Output", st.output, s)
            if let battery = st.battery {
                batteryRow(battery, s)
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

/// Carries a subview's natural (unconstrained) height up to `FitHeight`.
private struct DetailsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Uniformly scales its content down (never up) so it fits within `available`
/// height, then claims only the fitted height so it doesn't push its siblings.
/// The content still lays out at its natural size — the scale is a visual
/// transform — so text truncation and internal spacing are unaffected.
private struct FitHeight: ViewModifier {
    let available: CGFloat
    @State private var natural: CGFloat = 0

    func body(content: Content) -> some View {
        let scale = (natural > available && available > 0) ? available / natural : 1
        return content
            .onPreferenceChange(DetailsHeightKey.self) { natural = $0 }
            .scaleEffect(scale, anchor: .topLeading)
            .frame(height: natural > 0 ? min(natural, available) : nil, alignment: .topLeading)
    }
}
