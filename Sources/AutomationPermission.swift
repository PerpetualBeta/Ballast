import AppKit
import CoreServices

/// Read-only check of the Automation (Apple Events) permission for a target app
/// (Apple Music / Spotify), used to level the currently-playing track on
/// start-up. Uses `AEDeterminePermissionToAutomateTarget` with
/// `askUserIfNeeded: false`, so it never prompts. Only meaningful while the
/// target app is running (we don't launch it just to check).
enum AutomationPermission {

    enum Status { case authorized, denied, undetermined, notRunning }

    static func status(bundleID: String) -> Status {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            return .notRunning
        }
        var target = AEDesc()
        let created = Array(bundleID.utf8).withUnsafeBytes { buf in
            AECreateDesc(DescType(typeApplicationBundleID), buf.baseAddress, buf.count, &target) == noErr
        }
        guard created else { return .undetermined }
        defer { AEDisposeDesc(&target) }

        let result = AEDeterminePermissionToAutomateTarget(
            &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        switch result {
        case noErr:  return .authorized
        case -1743:  return .denied         // errAEEventNotPermitted
        case -1744:  return .undetermined   // errAEEventWouldRequireUserConsent
        default:     return .undetermined
        }
    }

    /// Combined status across Apple Music and Spotify (either granted wins).
    static var combined: Status {
        let m = status(bundleID: "com.apple.Music")
        let s = status(bundleID: "com.spotify.client")
        if m == .authorized || s == .authorized { return .authorized }
        if m == .denied || s == .denied { return .denied }
        if m == .notRunning && s == .notRunning { return .notRunning }
        return .undetermined
    }
}
