import Foundation

/// The real-time signal chain, run once per output IO cycle on interleaved
/// float audio pulled from the ring.
///
/// **Per-track normalisation anchored to the loudest part.** The goal is: pick
/// a comfortable level once, and have every track's *loudest* passage land
/// there — so nothing blasts your ears — while quieter passages stay quieter
/// (dynamics preserved). Because a real-time stream can't be analysed ahead of
/// time (a track may open quietly and swell), the anchor is discovered as the
/// track plays:
///
///   1. **Measure** source loudness through an ITU-R BS.1770 K-weighting
///      filter, smoothed to a sustained (~0.8 s) value.
///   2. Track the **loudest sustained level** seen since the last track change
///      and set the gain so *that* sits at the target. This value only rises,
///      so the gain only ever steps **down** within a track — never up — which
///      means no pumping: once the loud passages have been seen the gain holds
///      steady, and quiet passages simply play quieter.
///   3. A **track change** (or "Re-level now", or switching on) resets the
///      anchor so the next track gets its own gain.
///   4. A short look-ahead brickwall limiter guards the −1 dBFS ceiling.
///
/// Everything the IO thread touches is pre-allocated. No allocation, locks, or
/// blocking runtime calls happen in `processInterleaved`.
final class LoudnessProcessor {

    // MARK: Fixed capacities & design constants

    private static let maxChannels = 8
    private static let maxLookaheadFrames = 1024   // ≥ 5 ms look-ahead at 192 kHz

    /// Smoothing of the loudness estimate. Long enough that a single transient
    /// (a snare hit) doesn't define the anchor, short enough to follow a swell.
    private static let loudnessTauSeconds = 0.8
    /// Below this the signal is silence — the gain is held (a track's own quiet
    /// passages don't disturb the anchor).
    private static let silenceGateLUFS = -60.0
    /// Gain glide toward the target. Cutting is fast (protect the ears the
    /// instant a loud passage arrives); boosting — which only happens right
    /// after a track change — is gentler.
    private static let cutGlideTauSeconds = 0.15
    private static let boostGlideTauSeconds = 0.40
    private static let lookaheadSeconds = 0.0015
    private static let limiterReleaseSeconds = 0.100
    private static let loudnessOffset = -0.691          // BS.1770 LKFS/LUFS constant

    // MARK: Configuration (set off the IO thread)

    private var sampleRate: Double = 48_000
    private(set) var channelCount: Int = 2
    private var stage1 = BiquadCoefficients()
    private var stage2 = BiquadCoefficients()
    private var lookaheadFrames = 72
    private var limiterReleaseCoef = 0.001
    private var ceilingLinear = 0.891
    private var bypass = true

    // MARK: Live parameters (written from the main thread; read on the IO thread)

    private var targetLoudnessLUFS = BallastSettings.targetLoudnessDefault
    private var maxGainDB = BallastSettings.maxGainDefault

    // MARK: Gain / anchor state

    private var currentGainDB: Double = 0
    private var desiredGainDB: Double = 0
    private var anchorLoudnessLUFS = -120.0   // loudest sustained level this track (live mode)
    private var needsReanchor = true
    private var limiterEnv: Double = 1.0

    /// Finite ⇒ this is a *known* track: apply one fixed, dynamics-preserving
    /// gain from the learned whole-track loudness. NaN ⇒ live loud-anchored.
    private var knownIntegratedLUFS = Double.nan
    private var pendingMeterReset = false

    /// Measures the current track's true whole-track loudness so it can be
    /// learned. Read on the main thread at track end.
    let integratedMeter = IntegratedLoudnessMeter()
    var measuredIntegratedLUFS: Double { integratedMeter.integratedLUFS }
    var measuredContentSeconds: Double { integratedMeter.measuredSeconds }
    var isKnownTrack: Bool { knownIntegratedLUFS.isFinite }

    // MARK: Meters (written on IO thread, read on main — display only)

    private(set) var meterSourceLoudness: Float = -120
    private(set) var meterGainDB: Float = 0

    // MARK: Diagnostics

    var diagnosticsEnabled = false
    private(set) var dbgFrames = 0
    private(set) var dbgOutPeak: Float = 0

    // MARK: Pre-allocated IO-thread scratch

    private let s1z1, s1z2, s2z1, s2z2: UnsafeMutablePointer<Double>
    private let shortTermMS: UnsafeMutablePointer<Double>   // smoothed K-weighted mean-square per channel
    private let delayLine: UnsafeMutablePointer<Float>      // limiter look-ahead, channel-major
    private var delayPos = 0

    init() {
        let ch = Self.maxChannels
        s1z1 = .allocate(capacity: ch); s1z2 = .allocate(capacity: ch)
        s2z1 = .allocate(capacity: ch); s2z2 = .allocate(capacity: ch)
        shortTermMS = .allocate(capacity: ch)
        delayLine = .allocate(capacity: ch * Self.maxLookaheadFrames)
        for p in [s1z1, s1z2, s2z1, s2z2, shortTermMS] { p.initialize(repeating: 0, count: ch) }
        delayLine.initialize(repeating: 0, count: ch * Self.maxLookaheadFrames)
    }

    deinit {
        s1z1.deallocate(); s1z2.deallocate(); s2z1.deallocate(); s2z2.deallocate()
        shortTermMS.deallocate(); delayLine.deallocate()
    }

    // MARK: Configuration

    func configure(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        stage1 = KWeighting.stage1(sampleRate: sampleRate)
        stage2 = KWeighting.stage2(sampleRate: sampleRate)
        lookaheadFrames = max(1, min(Self.maxLookaheadFrames,
                                     Int((Self.lookaheadSeconds * sampleRate).rounded())))
        limiterReleaseCoef = 1.0 - exp(-1.0 / (Self.limiterReleaseSeconds * sampleRate))
        ceilingLinear = pow(10.0, BallastSettings.peakCeilingDBFS / 20.0)
        integratedMeter.configure(sampleRate: sampleRate)
        resetState()
        bypass = !(channelCount >= 1 && channelCount <= Self.maxChannels)
    }

    func resetState() {
        let ch = Self.maxChannels
        for p in [s1z1, s1z2, s2z1, s2z2, shortTermMS] { p.update(repeating: 0, count: ch) }
        delayLine.update(repeating: 0, count: ch * Self.maxLookaheadFrames)
        delayPos = 0
        currentGainDB = 0
        desiredGainDB = 0
        anchorLoudnessLUFS = -120
        needsReanchor = true
        knownIntegratedLUFS = .nan
        pendingMeterReset = false
        integratedMeter.reset()
        limiterEnv = 1.0
        meterSourceLoudness = -120
        meterGainDB = 0
    }

    func apply(targetLoudness: Double, maxGain: Double) {
        targetLoudnessLUFS = targetLoudness
        maxGainDB = maxGain
    }

    /// Start a new track. `knownIntegratedLUFS` non-nil ⇒ apply that learned
    /// loudness as a fixed gain; nil ⇒ discover the level live. Either way the
    /// integrated meter is reset so this play is measured afresh (to learn or
    /// refine). Called from the main thread; the IO thread acts on the flags.
    func beginTrack(knownIntegratedLUFS known: Double?) {
        knownIntegratedLUFS = known ?? .nan
        needsReanchor = true
        pendingMeterReset = true
    }

    /// Manual "Re-level now" — re-anchor the live pass and re-measure.
    func triggerReacquire() {
        needsReanchor = true
        pendingMeterReset = true
    }

    // MARK: Real-time processing (in place on interleaved [frames × channelCount])

    func processInterleaved(_ buf: UnsafeMutablePointer<Float>, frames: Int) {
        let ch = channelCount
        guard frames > 0, !bypass, ch >= 1, ch <= Self.maxChannels else {
            if diagnosticsEnabled { dbgFrames = frames; dbgOutPeak = AudioBufferSupport.peak(buf, count: frames * max(1, ch)) }
            return
        }

        if pendingMeterReset { pendingMeterReset = false; integratedMeter.reset() }

        let dt = Double(frames) / sampleRate
        let loudnessAlpha = 1.0 - exp(-dt / Self.loudnessTauSeconds)

        // ── Pass A: K-weighted mean-square per channel → smoothed loudness. ──
        var sumShortMS = 0.0
        var blockSumSquares = 0.0
        for c in 0..<ch {
            var z1a = s1z1[c], z2a = s1z2[c], z1b = s2z1[c], z2b = s2z2[c]
            var acc = 0.0
            var f = 0
            while f < frames {
                let x = Double(buf[f * ch + c])
                let y1 = stage1.b0 * x + z1a
                z1a = stage1.b1 * x - stage1.a1 * y1 + z2a
                z2a = stage1.b2 * x - stage1.a2 * y1
                let y2 = stage2.b0 * y1 + z1b
                z1b = stage2.b1 * y1 - stage2.a1 * y2 + z2b
                z2b = stage2.b2 * y1 - stage2.a2 * y2
                acc += y2 * y2
                f += 1
            }
            s1z1[c] = z1a; s1z2[c] = z2a; s2z1[c] = z1b; s2z2[c] = z2b
            blockSumSquares += acc
            shortTermMS[c] += (acc / Double(frames) - shortTermMS[c]) * loudnessAlpha
            sumShortMS += shortTermMS[c]
        }
        // Feed the (already K-weighted) power to the integrated meter to learn
        // this track's whole-track loudness.
        integratedMeter.add(sumSquares: blockSumSquares, frames: frames)

        let shortLoudness = sumShortMS > 0 ? Self.loudnessOffset + 10.0 * log10(sumShortMS) : -120.0
        meterSourceLoudness = Float(shortLoudness)
        let present = shortLoudness > Self.silenceGateLUFS

        // ── Per-track gain. ──
        if knownIntegratedLUFS.isFinite {
            // KNOWN track: one fixed gain from the learned whole-track loudness
            // → perfect from the first sample, full dynamics preserved.
            needsReanchor = false
            desiredGainDB = (targetLoudnessLUFS - knownIntegratedLUFS).clamped(to: -maxGainDB ... maxGainDB)
        } else if present {
            // UNKNOWN track: discover the level live, anchored to the loudest
            // sustained passage (only ever lowers the gain within a track).
            if needsReanchor {
                needsReanchor = false
                anchorLoudnessLUFS = shortLoudness
            } else if shortLoudness > anchorLoudnessLUFS {
                anchorLoudnessLUFS = shortLoudness
            }
            desiredGainDB = (targetLoudnessLUFS - anchorLoudnessLUFS).clamped(to: -maxGainDB ... maxGainDB)
        }
        // during silence (live mode): hold (silence × gain is still silence)

        // Glide the applied gain — fast down (protect), gentle up (only after a
        // re-anchor at a track change).
        let tau = desiredGainDB < currentGainDB ? Self.cutGlideTauSeconds : Self.boostGlideTauSeconds
        currentGainDB += (desiredGainDB - currentGainDB) * (1.0 - exp(-dt / tau))
        let linearGain = pow(10.0, currentGainDB / 20.0)
        meterGainDB = Float(currentGainDB)

        // ── Pass B: apply gain, then the look-ahead limiter (stereo-linked). ──
        let lookahead = lookaheadFrames
        var pos = delayPos
        var env = limiterEnv
        let ceiling = ceilingLinear
        let releaseCoef = limiterReleaseCoef

        var f = 0
        while f < frames {
            var peak = 0.0
            for c in 0..<ch {
                let g = Double(buf[f * ch + c]) * linearGain
                delayLine[c * Self.maxLookaheadFrames + pos] = Float(g)
                let a = abs(g); if a > peak { peak = a }
            }
            let required = peak > ceiling ? ceiling / peak : 1.0
            if required < env { env = required } else { env += (1.0 - env) * releaseCoef }

            let readPos = (pos + 1) % lookahead
            for c in 0..<ch {
                buf[f * ch + c] = Float(Double(delayLine[c * Self.maxLookaheadFrames + readPos]) * env)
            }
            pos = (pos + 1) % lookahead
            f += 1
        }
        delayPos = pos
        limiterEnv = env

        if diagnosticsEnabled { dbgFrames = frames; dbgOutPeak = AudioBufferSupport.peak(buf, count: frames * ch) }
    }
}
