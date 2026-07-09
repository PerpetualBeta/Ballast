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
}

/// Tracks the currently-playing track (metadata + artwork) and Ballast's live
/// stats for the visualiser's Now Playing mode. Metadata refreshes on the
/// track-change notifications the engine uses; stats are polled from the engine
/// on a timer (an ObservableObject drives re-renders reliably, where a hosted
/// TimelineView did not).
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published var artwork: NSImage?
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var hasTrack = false
    @Published var stats = NowPlayingStats()

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
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshStats() }
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

    func refresh() {
        NowPlayingProbe.nowPlaying { [weak self] info in
            guard let self else { return }
            self.artwork = info?.artwork
            self.title = info?.title ?? ""
            self.artist = info?.artist ?? ""
            self.album = info?.album ?? ""
            self.hasTrack = (info != nil)
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
            love: e.currentTrackLove
        )
        if next != stats { stats = next }
    }
}

/// Album artwork as the hero, plus track details, a "love" rating (how often
/// you play this track vs the rest of your library), the play count, and
/// Ballast's live level readout. Sizes derive from the smaller window dimension
/// and the block is centred, so it scales without clipping.
struct NowPlayingView: View {
    @ObservedObject var model: NowPlayingModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let s = min(w, h)
            ZStack {
                background(s)
                content(w: w, h: h, s: s)
                    .padding(s * 0.06)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func content(w: CGFloat, h: CGFloat, s: CGFloat) -> some View {
        if w > h * 1.25 {
            HStack(spacing: s * 0.06) { art(min(h * 0.72, w * 0.4)); details(s) }
        } else {
            VStack(spacing: s * 0.05) { art(min(h * 0.45, w * 0.72)); details(s) }
        }
    }

    @ViewBuilder private func background(_ s: CGFloat) -> some View {
        if let art = model.artwork {
            Image(nsImage: art).resizable().scaledToFill().blur(radius: s * 0.12).overlay(Color.black.opacity(0.5))
        } else {
            LinearGradient(colors: [Color(white: 0.08), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
        }
    }

    private func art(_ side: CGFloat) -> some View {
        Group {
            if let a = model.artwork {
                Image(nsImage: a).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.18)
                    Image(systemName: "music.note").font(.system(size: side * 0.3)).foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.06, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: side * 0.05, y: side * 0.02)
    }

    private func details(_ s: CGFloat) -> some View {
        let st = model.stats
        return VStack(alignment: .leading, spacing: s * 0.026) {
            if model.hasTrack {
                Text(model.title).font(.system(size: s * 0.088, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(.white)
                Text(model.artist).font(.system(size: s * 0.058))
                    .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white.opacity(0.85))
                if !model.album.isEmpty {
                    Text(model.album).font(.system(size: s * 0.046))
                        .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white.opacity(0.6))
                }
                loveLine(st, s)
            } else {
                Text("Nothing playing").font(.system(size: s * 0.07, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            }
            statsPanel(st, s).padding(.top, s * 0.03)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hearts (play-count percentile vs the library) + the play count.
    @ViewBuilder private func loveLine(_ st: NowPlayingStats, _ s: CGFloat) -> some View {
        if st.plays > 0 {
            HStack(spacing: s * 0.016) {
                ForEach(0..<5) { i in
                    Image(systemName: i < heartCount(st.love) ? "heart.fill" : "heart")
                        .font(.system(size: s * 0.04))
                        .foregroundStyle(Color(red: 0.96, green: 0.36, blue: 0.46))
                }
                Text(st.plays == 1 ? "1 play" : "\(st.plays) plays")
                    .font(.system(size: s * 0.044)).foregroundStyle(.white.opacity(0.75))
                    .padding(.leading, s * 0.02)
            }
            .padding(.top, s * 0.008)
        }
    }

    private func heartCount(_ love: Double?) -> Int {
        guard let love else { return 1 }
        return min(5, max(1, Int((love * 4).rounded()) + 1))
    }

    private func statsPanel(_ st: NowPlayingStats, _ s: CGFloat) -> some View {
        VStack(spacing: s * 0.015) {
            statRow("Source", st.active && st.source > -100 ? String(format: "%.1f LUFS", st.source) : "\u{2014}", s)
            statRow("Adjustment", st.active ? String(format: "%+.1f dB", st.gain) : "\u{2014}", s)
            statRow("Target", String(format: "%.0f LUFS", st.target), s)
            statRow("This track", st.active ? (st.known ? "Known \u{2014} fixed level" : "Learning\u{2026}") : "\u{2014}", s)
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
            Text(value).font(.system(size: s * 0.042, design: .rounded)).monospacedDigit()
                .lineLimit(1).foregroundStyle(.white)
        }
    }
}
