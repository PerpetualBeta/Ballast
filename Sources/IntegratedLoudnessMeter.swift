import Foundation

/// Streaming ITU-R BS.1770 / EBU R128 **integrated** loudness — the gated,
/// whole-programme number (what ReplayGain/Sound Check store per track).
///
/// It is fed the already-K-weighted power the `LoudnessProcessor` computes each
/// IO block (sum of squares across channels + frame count), gathers it into
/// 400 ms gating blocks stepped every 100 ms, and histograms their loudness.
/// The integrated value applies the two R128 gates (absolute −70 LUFS, then
/// relative −10 LU below the ungated mean) over the histogram — the same
/// approach libebur128 uses — so it can be read at any time on the main thread.
final class IntegratedLoudnessMeter {

    private static let blockSeconds = 0.400
    private static let hopSeconds = 0.100
    private static let absoluteGateLUFS = -70.0
    private static let relativeGateLU = -10.0
    private static let loudnessOffset = -0.691

    // Histogram: 0.1 LU bins from −70 to +5 LUFS.
    private static let binWidth = 0.1
    private static let binBase = -70.0
    private static let binCount = 751

    private var sampleRate = 48_000.0
    private var hopFrames = 4800
    private let hopHistory = 4                     // 4 × 100 ms = 400 ms

    private let histogram: UnsafeMutablePointer<Int32>
    private let hopSumSquares: UnsafeMutablePointer<Double>  // ring of last `hopHistory` hops
    private let hopFrameCounts: UnsafeMutablePointer<Int>
    private var hopFill = 0
    private var hopIndex = 0
    private var filledHops = 0

    private var curSumSquares = 0.0
    private var curFrames = 0

    /// Latest integrated loudness (LUFS), recomputed as blocks arrive. Written
    /// on the IO thread, read on the main thread — display/store only.
    private(set) var integratedLUFS: Double = -120

    /// Seconds of above-gate (actual audio) content measured — excludes
    /// silence and pauses, so it reflects how much of the track was really
    /// heard. Read on the main thread.
    private var contentBlocks = 0
    var measuredSeconds: Double { Double(contentBlocks) * Self.hopSeconds }

    init() {
        histogram = .allocate(capacity: Self.binCount)
        hopSumSquares = .allocate(capacity: hopHistory)
        hopFrameCounts = .allocate(capacity: hopHistory)
        histogram.initialize(repeating: 0, count: Self.binCount)
        hopSumSquares.initialize(repeating: 0, count: hopHistory)
        hopFrameCounts.initialize(repeating: 0, count: hopHistory)
    }

    deinit {
        histogram.deallocate(); hopSumSquares.deallocate(); hopFrameCounts.deallocate()
    }

    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        hopFrames = max(1, Int(Self.hopSeconds * sampleRate))
        reset()
    }

    func reset() {
        histogram.update(repeating: 0, count: Self.binCount)
        hopSumSquares.update(repeating: 0, count: hopHistory)
        hopFrameCounts.update(repeating: 0, count: hopHistory)
        hopFill = 0; hopIndex = 0; filledHops = 0
        curSumSquares = 0; curFrames = 0
        contentBlocks = 0
        integratedLUFS = -120
    }

    /// Feed one IO block's channel-summed K-weighted sum-of-squares.
    func add(sumSquares: Double, frames: Int) {
        curSumSquares += sumSquares
        curFrames += frames
        hopFill += frames
        while hopFill >= hopFrames {
            // A 100 ms hop completed. Push it into the ring.
            hopSumSquares[hopIndex] = curSumSquares
            hopFrameCounts[hopIndex] = curFrames
            hopIndex = (hopIndex + 1) % hopHistory
            filledHops = min(filledHops + 1, hopHistory)
            curSumSquares = 0; curFrames = 0
            hopFill -= hopFrames

            if filledHops == hopHistory { accumulateBlock() }
        }
    }

    /// Form the current 400 ms block from the last 4 hops and histogram it.
    private func accumulateBlock() {
        var ss = 0.0
        var n = 0
        for i in 0..<hopHistory { ss += hopSumSquares[i]; n += hopFrameCounts[i] }
        guard n > 0 else { return }
        let meanSquare = ss / Double(n)
        guard meanSquare > 0 else { return }
        let loudness = Self.loudnessOffset + 10.0 * log10(meanSquare)
        guard loudness >= Self.absoluteGateLUFS else { return }   // absolute gate
        let bin = min(Self.binCount - 1, max(0, Int((loudness - Self.binBase) / Self.binWidth)))
        histogram[bin] += 1
        contentBlocks += 1
        integratedLUFS = computeIntegrated()
    }

    /// Apply the absolute + relative gates across the histogram.
    private func computeIntegrated() -> Double {
        // Ungated mean power (all bins are ≥ −70 by construction).
        var sumPower = 0.0
        var total = 0
        for i in 0..<Self.binCount {
            let c = Int(histogram[i]); guard c > 0 else { continue }
            sumPower += Double(c) * binPower(i)
            total += c
        }
        guard total > 0 else { return -120 }
        let ungated = Self.loudnessOffset + 10.0 * log10(sumPower / Double(total))
        let relativeGate = ungated + Self.relativeGateLU

        // Gated mean power (bins at or above the relative gate).
        var gSumPower = 0.0
        var gTotal = 0
        for i in 0..<Self.binCount {
            let c = Int(histogram[i]); guard c > 0 else { continue }
            if binLoudness(i) >= relativeGate {
                gSumPower += Double(c) * binPower(i)
                gTotal += c
            }
        }
        guard gTotal > 0 else { return ungated }
        return Self.loudnessOffset + 10.0 * log10(gSumPower / Double(gTotal))
    }

    private func binLoudness(_ i: Int) -> Double { Self.binBase + (Double(i) + 0.5) * Self.binWidth }
    private func binPower(_ i: Int) -> Double { pow(10.0, (binLoudness(i) - Self.loudnessOffset) / 10.0) }
}
