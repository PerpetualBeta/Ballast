import Foundation

/// Persisted, user-tunable parameters for the loudness engine.
///
/// The source of truth is `UserDefaults.standard`; the SwiftUI settings write
/// here and the engine reads a snapshot into its real-time DSP state via
/// `LoudnessProcessor.apply(_:)`. Every bound and default below is a product
/// design choice, named here rather than sprinkled through the code as a
/// literal.
enum BallastSettings {

    // MARK: Keys
    private enum Key {
        static let enabled              = "levellingEnabled"
        static let targetLoudness       = "targetLoudnessLUFS"
        static let maxGain              = "maxGainDB"
        static let showTrackTitle       = "showTrackTitle"
        static let maxTitleLength       = "maxTitleLength"
        static let onboarded            = "hasCompletedOnboarding"
        static let visualizerMode       = "visualizerMode"
        static let visualizerKeepOnTop  = "visualizerKeepOnTop"
        static let visualizerColour     = "visualizerColourSource"
        static let visualizerFrame      = "visualizerFrame"
        static let excludedApps         = "excludedApps"
    }

    // MARK: Design bounds & defaults

    /// EBU R128 programme-loudness target for broadcast is −23 LUFS; streaming
    /// services normalise nearer −14. −16 sits between the two and is a
    /// comfortable "sensible listening level" default. Fully user-tunable.
    static let targetLoudnessDefault: Double = -16.0
    static let targetLoudnessRange: ClosedRange<Double> = -30.0 ... -8.0

    /// How far the AGC is allowed to push a quiet or loud source toward the
    /// target. A ceiling on boost also caps how far the noise floor of a quiet
    /// source is lifted.
    static let maxGainDefault: Double = 12.0
    static let maxGainRange: ClosedRange<Double> = 0.0 ... 24.0

    /// Output true-peak ceiling for the look-ahead limiter. −1 dBFS is the
    /// widely-used safe headroom that keeps inter-sample peaks and downstream
    /// codecs from clipping.
    static let peakCeilingDBFS: Double = -1.0

    /// Menu-bar track-title display: opt-in, and its maximum length in
    /// characters (grapheme clusters) before the title is truncated.
    static let maxTitleLengthDefault = 30
    static let maxTitleLengthRange: ClosedRange<Int> = 10 ... 60

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.targetLoudness: targetLoudnessDefault,
            Key.maxGain: maxGainDefault,
            Key.maxTitleLength: maxTitleLengthDefault,
            // `enabled` is deliberately NOT registered: a missing key reads as
            // false, so Ballast starts inert and only taps the system audio
            // once the user opts in (which is also when macOS prompts for the
            // audio-capture permission).
        ])
    }

    // MARK: Accessors

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    static var targetLoudness: Double {
        get { UserDefaults.standard.double(forKey: Key.targetLoudness) }
        set { UserDefaults.standard.set(newValue.clamped(to: targetLoudnessRange), forKey: Key.targetLoudness) }
    }

    static var maxGain: Double {
        get { UserDefaults.standard.double(forKey: Key.maxGain) }
        set { UserDefaults.standard.set(newValue.clamped(to: maxGainRange), forKey: Key.maxGain) }
    }

    static var showTrackTitle: Bool {
        get { UserDefaults.standard.bool(forKey: Key.showTrackTitle) }
        set { UserDefaults.standard.set(newValue, forKey: Key.showTrackTitle) }
    }

    static var maxTitleLength: Int {
        get { UserDefaults.standard.integer(forKey: Key.maxTitleLength) }
        set { UserDefaults.standard.set(min(max(newValue, maxTitleLengthRange.lowerBound), maxTitleLengthRange.upperBound), forKey: Key.maxTitleLength) }
    }

    static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Key.onboarded) }
        set { UserDefaults.standard.set(newValue, forKey: Key.onboarded) }
    }

    static var visualizerMode: String {
        get { UserDefaults.standard.string(forKey: Key.visualizerMode) ?? "aurora" }
        set { UserDefaults.standard.set(newValue, forKey: Key.visualizerMode) }
    }

    static var visualizerKeepOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: Key.visualizerKeepOnTop) }
        set { UserDefaults.standard.set(newValue, forKey: Key.visualizerKeepOnTop) }
    }

    static var visualizerColourSource: String {
        get { UserDefaults.standard.string(forKey: Key.visualizerColour) ?? "builtin" }
        set { UserDefaults.standard.set(newValue, forKey: Key.visualizerColour) }
    }

    /// The visualiser's last frame, in screen coordinates, as `NSStringFromRect`.
    ///
    /// The window is built the first time it is opened, which is usually long
    /// after login, so RememberMyWindows logs `Skipping 'cc.jorviksoftware.Ballast'
    /// — app has no windows` and never restores it. No external window manager
    /// can place a window that does not exist yet, so Ballast keeps its own.
    ///
    /// Deliberately not `setFrameAutosaveName`: AppKit keys an autosaved frame by
    /// screen configuration and re-asserts it, so unplugging and replugging a
    /// display reopens the window at its pre-unplug size. This value is read once
    /// when the window is built, checked against the displays attached at that
    /// moment, and never re-asserted.
    static var visualizerFrame: NSRect? {
        get {
            guard let s = UserDefaults.standard.string(forKey: Key.visualizerFrame) else { return nil }
            let r = NSRectFromString(s)
            return r.isEmpty ? nil : r
        }
        set {
            guard let r = newValue else {
                UserDefaults.standard.removeObject(forKey: Key.visualizerFrame); return
            }
            UserDefaults.standard.set(NSStringFromRect(r), forKey: Key.visualizerFrame)
        }
    }

    /// 16:9, and large enough to read the Now Playing text at a glance.
    static let visualizerDefaultSize = NSSize(width: 720, height: 405)

    /// How much of a restored frame must land on some attached display for it to
    /// be reused. The window is drag-anywhere, so any decent visible patch can be
    /// grabbed; the check exists to catch a frame saved on a display that is no
    /// longer here, which would otherwise open the window somewhere unreachable.
    static let visualizerMinVisibleFraction: CGFloat = 0.5

    /// Bundle IDs of apps the user has excluded from levelling (see `AppExclusions`).
    static var excludedBundleIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.excludedApps) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Key.excludedApps) }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
