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

    weak var engine: BallastEngine?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

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
        }
    }

    func refreshStats() {
        guard let e = engine else { return }
        let next = NowPlayingStats(
            active: e.isActive,
            source: Double(e.processor.meterSourceLoudness),
            gain: Double(e.processor.meterGainDB),
            target: BallastSettings.targetLoudness,
            known: e.currentTrackKnown,
            learned: e.libraryCount,
            output: e.currentOutputDeviceName ?? "\u{2014}",
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
        if w > h * 1.25 {
            HStack(spacing: s * 0.06) { art(min(h * 0.72, w * 0.4), paused: paused); details(s, paused: paused) }
        } else {
            VStack(spacing: s * 0.05) { art(min(h * 0.45, w * 0.72), paused: paused); details(s, paused: paused) }
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

    private func details(_ s: CGFloat, paused: Bool) -> some View {
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
            loveLine(st, s)
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
            }
            statRow("Learned", "\(st.learned) tracks", s)
            statRow("Output", st.output, s)
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
}
