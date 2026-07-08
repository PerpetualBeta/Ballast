import Foundation

/// System audio-capture (Core Audio process tap) permission.
///
/// This is its own TCC category — `kTCCServiceAudioCapture`, declared in
/// Info.plist via `NSAudioCaptureUsageDescription` — separate from the
/// microphone. Apple ships **no public API** to check or request it, so (like
/// Apple's own AudioCap sample) we call the two private `TCC.framework`
/// functions directly. Every call is defensive: if the private symbols ever
/// vanish, `status` reports `.undetermined` and we still attempt the tap,
/// which degrades to the OS's own first-use prompt.
enum AudioCapturePermission {

    enum Status { case authorized, denied, undetermined }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    // The callback must be @escaping: TCC stores the block and invokes it
    // asynchronously after the prompt is dismissed. (Marking it non-escaping
    // traps at runtime the moment TCC holds onto it.)
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let tccHandle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFn: PreflightFn? = {
        guard let h = tccHandle, let sym = dlsym(h, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    private static let requestFn: RequestFn? = {
        guard let h = tccHandle, let sym = dlsym(h, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFn.self)
    }()

    /// Current authorisation. `TCCAccessPreflight` returns 0 authorized,
    /// 1 denied, anything else not-yet-determined.
    static var status: Status {
        guard let preflightFn else { return .undetermined }
        switch preflightFn(service, nil) {
        case 0:  return .authorized
        case 1:  return .denied
        default: return .undetermined
        }
    }

    /// Prompt for permission (or immediately report the standing decision).
    /// `completion` is always delivered on the main queue.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let requestFn else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        requestFn(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
