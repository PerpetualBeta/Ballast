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
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
