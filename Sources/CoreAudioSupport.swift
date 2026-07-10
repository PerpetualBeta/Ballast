import CoreAudio
import Foundation

/// Thin, typed helpers over the Core Audio HAL property API. Every call is a
/// plain `AudioObjectGetPropertyData` with the boilerplate (address, size,
/// status check) folded away.
enum CoreAudioSupport {

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: Fixed-size scalar reads

    private static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                  _ initial: T) -> T? {
        var addr = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    private static func cfString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    // MARK: Devices

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let dev = scalar(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)),
              dev != 0 else { return nil }
        return dev
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        cfString(device, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ device: AudioObjectID) -> String? {
        cfString(device, kAudioObjectPropertyName)
    }

    static func deviceSampleRate(_ device: AudioObjectID) -> Double? {
        scalar(device, kAudioDevicePropertyNominalSampleRate, Float64(0))
    }

    /// The device's physical transport (`kAudioDeviceTransportType…`), e.g.
    /// built-in, USB, or Bluetooth. Lets callers tell a battery-powered
    /// wireless output apart from a wired/built-in one before doing any
    /// (more expensive) battery lookup.
    static func deviceTransportType(_ device: AudioObjectID) -> UInt32? {
        scalar(device, kAudioDevicePropertyTransportType, UInt32(0))
    }

    // MARK: Processes

    /// Translate a Unix PID to its Core Audio process object, so the app can
    /// exclude itself from a global tap (otherwise our own re-injected audio
    /// would be captured and muted along with everyone else's).
    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var inputPID = pid
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &inputPID) { pidPtr in
            AudioObjectGetPropertyData(system, &addr,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr,
                                       &size, &object)
        }
        return status == noErr && object != 0 ? object : nil
    }

    // MARK: Taps

    static func tapUID(_ tap: AudioObjectID) -> String? {
        cfString(tap, kAudioTapPropertyUID)
    }

    static func tapStreamFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        scalar(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
    }

    // MARK: Default-output-device change notifications

    /// Registers `handler` to fire whenever the system default output device
    /// changes. Returns the block so the caller can remove it later.
    static func addDefaultOutputDeviceListener(
        queue: DispatchQueue,
        _ handler: @escaping () -> Void
    ) -> AudioObjectPropertyListenerBlock? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(system, &addr, queue, block)
        return status == noErr ? block : nil
    }

    static func removeDefaultOutputDeviceListener(
        queue: DispatchQueue,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(system, &addr, queue, block)
    }
}
