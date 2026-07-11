import CoreAudio
import Foundation

/// A measurement-only Core Audio tap scoped to a *single* process — the active
/// Music/Spotify — so loudness learning sees ONLY the music and never the
/// system sounds or other-app audio carried by the global output tap.
///
/// It runs its own input IOProc on a private aggregate clocked by the same
/// output device as the main graph, so it delivers at the same sample rate. It
/// never produces output; it only feeds the loudness measurement through
/// `onBlock`. Deliberately NOT `@MainActor`: `build`/`teardown` are driven from
/// the main thread, but the IOProc block touches it from the audio thread (the
/// same pattern as `LoudnessProcessor` / `AudioRingBuffer`).
final class MeasurementTap {

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private var scratch: UnsafeMutablePointer<Float>?
    private let maxFrames: Int
    private(set) var channels = 0

    /// Invoked on the IOProc thread with the isolated, interleaved music audio
    /// `(buffer, frames, channels)`. Set by the owner to drive measurement.
    var onBlock: ((UnsafeMutablePointer<Float>, Int, Int) -> Void)?

    /// Peak magnitude of the most recent block — IO thread → main, display only.
    private(set) var dbgPeak: Float = 0

    var isRunning: Bool { procID != nil }

    init(maxFrames: Int) { self.maxFrames = maxFrames }

    /// Build and start the tap for `process`, clocked by `outputDeviceUID`.
    /// Returns false (and cleans up) on any failure.
    func build(process: AudioObjectID, outputDeviceUID: String) -> Bool {
        let desc = CATapDescription(stereoMixdownOfProcesses: [process])
        desc.name = "Ballast Measurement"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted          // measurement only — never mute the music here

        var newTap = AudioObjectID(0)
        guard AudioHardwareCreateProcessTap(desc, &newTap) == noErr, newTap != 0,
              let tapUID = CoreAudioSupport.tapUID(newTap) else {
            teardown(); return false
        }
        tapID = newTap
        channels = Int(CoreAudioSupport.tapStreamFormat(tapID)?.mChannelsPerFrame ?? 2)

        let aggUID = "cc.jorviksoftware.Ballast.measure.\(getpid())"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ballast Measurement",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
        var newAgg = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAgg) == noErr, newAgg != 0 else {
            teardown(); return false
        }
        aggregateID = newAgg

        let count = maxFrames * max(1, channels)
        let sc = UnsafeMutablePointer<Float>.allocate(capacity: count)
        sc.initialize(repeating: 0, count: count)
        scratch = sc

        let ch = channels, maxF = maxFrames
        let selfCtx = Unmanaged.passUnretained(self).toOpaque()
        let block: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            let me = Unmanaged<MeasurementTap>.fromOpaque(selfCtx).takeUnretainedValue()
            let frames = AudioBufferSupport.interleave(inInputData, into: sc, channels: ch, maxFrames: maxF)
            guard frames > 0 else { return }
            me.dbgPeak = AudioBufferSupport.peak(sc, count: frames * ch)
            me.onBlock?(sc, frames, ch)
        }
        var newProc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil, block) == noErr,
              let proc = newProc else {
            teardown(); return false
        }
        procID = proc

        guard AudioDeviceStart(aggregateID, proc) == noErr else { teardown(); return false }
        return true
    }

    func teardown() {
        if aggregateID != 0, let proc = procID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        procID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        scratch?.deallocate(); scratch = nil
        channels = 0
        dbgPeak = 0
    }
}
