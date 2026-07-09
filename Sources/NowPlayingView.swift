import SwiftUI
import AppKit

/// Tracks the currently-playing track (title / artist / album / artwork) for
/// the visualiser's Now Playing mode. Refreshes on the same distributed
/// track-change notifications the engine uses, plus once when shown.
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published var artwork: NSImage?
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var hasTrack = false

    private var observers: [NSObjectProtocol] = []

    func start() {
        if observers.isEmpty {
            let center = DistributedNotificationCenter.default()
            for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
                observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    self?.refresh()
                })
            }
        }
        refresh()
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
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
}

/// Album artwork as the hero, plus track details and Ballast's live level
/// readout — so the stats can live here instead of the menu bar. Sizes derive
/// from the smaller window dimension and the block is centred, so it scales
/// with the window without clipping.
struct NowPlayingView: View {
    let engine: BallastEngine
    @ObservedObject var model: NowPlayingModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
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
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func content(w: CGFloat, h: CGFloat, s: CGFloat) -> some View {
        if w > h * 1.25 {
            HStack(spacing: s * 0.06) {
                art(min(h * 0.72, w * 0.4))
                details(s)
            }
        } else {
            VStack(spacing: s * 0.05) {
                art(min(h * 0.45, w * 0.72))
                details(s)
            }
        }
    }

    @ViewBuilder private func background(_ s: CGFloat) -> some View {
        if let art = model.artwork {
            Image(nsImage: art).resizable().scaledToFill()
                .blur(radius: s * 0.12).overlay(Color.black.opacity(0.5))
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
        VStack(alignment: .leading, spacing: s * 0.028) {
            if model.hasTrack {
                Text(model.title).font(.system(size: s * 0.088, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(.white)
                Text(model.artist).font(.system(size: s * 0.058))
                    .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white.opacity(0.85))
                if !model.album.isEmpty {
                    Text(model.album).font(.system(size: s * 0.046))
                        .lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(.white.opacity(0.6))
                }
            } else {
                Text("Nothing playing").font(.system(size: s * 0.07, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            }
            stats(s).padding(.top, s * 0.03)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stats(_ s: CGFloat) -> some View {
        let active = engine.isActive
        let src = engine.processor.meterSourceLoudness
        let gain = engine.processor.meterGainDB
        return VStack(spacing: s * 0.016) {
            statRow("Source", active && src > -100 ? String(format: "%.1f LUFS", src) : "\u{2014}", s)
            statRow("Adjustment", active ? String(format: "%+.1f dB", gain) : "\u{2014}", s)
            statRow("Target", String(format: "%.0f LUFS", BallastSettings.targetLoudness), s)
            statRow("This track", active ? (engine.currentTrackKnown ? "Known \u{2014} fixed level" : "Learning\u{2026}") : "\u{2014}", s)
            statRow("Learned", "\(engine.libraryCount) tracks", s)
            statRow("Output", engine.currentOutputDeviceName ?? "\u{2014}", s)
        }
        .padding(s * 0.038)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: s * 0.03, style: .continuous))
        .frame(maxWidth: s * 1.1, alignment: .leading)
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
