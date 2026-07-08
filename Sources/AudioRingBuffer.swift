import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer ring of interleaved float
/// frames.
///
/// The input IOProc (producer) writes the tapped mix; the output IOProc
/// (consumer) drains it, applies the DSP, and plays it. Both callbacks run on
/// real-time threads driven by the *same* hardware clock (the tap aggregate is
/// clocked by the output device), so the fill level stays near-constant — the
/// ring only has to absorb the phase offset between the two callbacks plus a
/// small priming cushion.
///
/// Correctness rests on release/acquire ordering of the two indices: the
/// producer publishes `writeIndex` with `.releasing` *after* its `memcpy`, and
/// the consumer reads it with `.acquiring` before touching the data, so it
/// never reads frames that aren't fully written.
final class AudioRingBuffer {
    private let storage: UnsafeMutablePointer<Float>
    private let capacityFrames: Int
    let channels: Int

    private let writeIndex = Atomic<UInt64>(0)   // frames written, monotonic
    private let readIndex  = Atomic<UInt64>(0)   // frames read, monotonic

    /// The consumer stays silent until the ring first fills to this depth,
    /// establishing a latency cushion so the two same-clock callbacks don't
    /// underrun each other at steady state.
    let primeFrames: Int
    private let primed = Atomic<Bool>(false)

    // Diagnostics (all lock-free; read on the main thread).
    let dbgWriteCallbacks = Atomic<UInt64>(0)
    let dbgReadCallbacks  = Atomic<UInt64>(0)
    let dbgOverruns       = Atomic<UInt64>(0)
    let dbgUnderruns      = Atomic<UInt64>(0)
    private let dbgInputPeakBits = Atomic<UInt32>(0)

    init(capacityFrames: Int, channels: Int, primeFrames: Int) {
        self.capacityFrames = capacityFrames
        self.channels = channels
        self.primeFrames = min(primeFrames, capacityFrames / 2)
        storage = .allocate(capacity: capacityFrames * channels)
        storage.initialize(repeating: 0, count: capacityFrames * channels)
    }

    deinit { storage.deallocate() }

    var availableFrames: Int {
        Int(writeIndex.load(ordering: .acquiring) &- readIndex.load(ordering: .relaxed))
    }

    var dbgInputPeak: Float { Float(bitPattern: dbgInputPeakBits.load(ordering: .relaxed)) }
    func setDbgInputPeak(_ v: Float) { dbgInputPeakBits.store(v.bitPattern, ordering: .relaxed) }

    /// Producer: append `frames` interleaved frames. On overrun, drops the
    /// oldest audio to make room (favouring the freshest signal).
    func write(_ src: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let used = Int(w &- r)
        if frames > capacityFrames - used {
            let drop = UInt64((frames - (capacityFrames - used)))
            readIndex.store(r &+ drop, ordering: .releasing)
            dbgOverruns.wrappingAdd(1, ordering: .relaxed)
        }
        var pos = Int(w % UInt64(capacityFrames))
        var remaining = frames
        var srcFrame = 0
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - pos)
            memcpy(storage + pos * channels,
                   src + srcFrame * channels,
                   chunk * channels * MemoryLayout<Float>.size)
            pos = (pos + chunk) % capacityFrames
            srcFrame += chunk
            remaining -= chunk
        }
        writeIndex.store(w &+ UInt64(frames), ordering: .releasing)
    }

    /// Consumer entry point: silent until the ring first reaches `primeFrames`,
    /// then delegates to `read`.
    func readPrimed(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        if !primed.load(ordering: .acquiring) {
            if availableFrames >= primeFrames {
                primed.store(true, ordering: .releasing)
            } else {
                return 0
            }
        }
        return read(into: dst, frames: frames)
    }

    /// Consumer: pull up to `frames`; returns the number actually read. The
    /// caller is responsible for zero-filling any shortfall.
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let toRead = min(frames, Int(w &- r))
        guard toRead > 0 else {
            dbgUnderruns.wrappingAdd(1, ordering: .relaxed)
            return 0
        }
        var pos = Int(r % UInt64(capacityFrames))
        var remaining = toRead
        var dstFrame = 0
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - pos)
            memcpy(dst + dstFrame * channels,
                   storage + pos * channels,
                   chunk * channels * MemoryLayout<Float>.size)
            pos = (pos + chunk) % capacityFrames
            dstFrame += chunk
            remaining -= chunk
        }
        readIndex.store(r &+ UInt64(toRead), ordering: .releasing)
        if toRead < frames { dbgUnderruns.wrappingAdd(1, ordering: .relaxed) }
        return toRead
    }
}
