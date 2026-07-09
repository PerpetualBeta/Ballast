import Foundation
import Synchronization

/// Shared, lock-free hand-off of live audio from the output IO thread to the
/// visualiser's render thread. The audio thread pushes a mono downmix into a
/// ring (only while the visualiser window is open); the renderer reads the most
/// recent window each frame for its FFT and waveform, plus smoothed per-channel
/// levels for the VU meter. Visual-only, so relaxed ordering and the odd torn
/// read are fine.
final class VisualizerFeed {
    static let shared = VisualizerFeed()

    static let capacity = 16384          // mono samples (power of two)
    private let buffer: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<UInt64>(0)

    /// Set true while the visualiser window is visible; when false, `push`
    /// returns immediately so there's zero cost with the window closed.
    let active = Atomic<Bool>(false)

    // Smoothed per-channel level (0...1-ish) for analogue VU needles.
    private(set) var levelL: Float = 0
    private(set) var levelR: Float = 0

    private init() {
        buffer = .allocate(capacity: Self.capacity)
        buffer.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { buffer.deallocate() }

    /// Audio thread: append `frames` of interleaved float audio (downmixed).
    func push(interleaved buf: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard active.load(ordering: .relaxed) else { return }
        guard frames > 0, channels > 0 else { return }

        let cap = Self.capacity
        var w = Int(writeIndex.load(ordering: .relaxed) % UInt64(cap))
        var l = levelL, r = levelR
        let smoothing: Float = 0.15
        var f = 0
        while f < frames {
            let base = f * channels
            var mix: Float = 0
            for c in 0..<channels { mix += buf[base + c] }
            buffer[w] = mix / Float(channels)
            w = (w + 1) % cap

            let sl = abs(buf[base])
            let sr = channels > 1 ? abs(buf[base + 1]) : sl
            l += (sl - l) * smoothing
            r += (sr - r) * smoothing
            f += 1
        }
        levelL = l; levelR = r
        writeIndex.wrappingAdd(UInt64(frames), ordering: .relaxed)
    }

    /// Render thread: copy the most recent `count` samples, oldest-first.
    func latest(into out: UnsafeMutablePointer<Float>, count: Int) {
        let cap = Self.capacity
        let n = min(count, cap)
        let end = Int(writeIndex.load(ordering: .relaxed) % UInt64(cap))
        var idx = (end - n + cap) % cap
        for i in 0..<n { out[i] = buffer[idx]; idx = (idx + 1) % cap }
        if n < count { for i in n..<count { out[i] = 0 } }
    }
}
