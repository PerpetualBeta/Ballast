import SwiftUI
import AppKit

/// App-specific settings, dropped into `JorvikSettingsView`'s form (which adds
/// the shared "Launch at Login" section itself).
@MainActor
struct BallastSettingsContent: View {
    let delegate: AppDelegate

    @State private var enabled: Bool
    @State private var target: Double
    @State private var maxGain: Double
    @State private var showTitle: Bool
    @State private var maxTitleLen: Int

    init(delegate: AppDelegate) {
        self.delegate = delegate
        _enabled = State(initialValue: delegate.engine.isActive)
        _target = State(initialValue: BallastSettings.targetLoudness)
        _maxGain = State(initialValue: BallastSettings.maxGain)
        _showTitle = State(initialValue: BallastSettings.showTrackTitle)
        _maxTitleLen = State(initialValue: BallastSettings.maxTitleLength)
    }

    var body: some View {
        Section("Loudness") {
            Toggle("Level system audio", isOn: $enabled)
                .onChange(of: enabled) { _, newValue in
                    if newValue { delegate.engine.start() } else { delegate.engine.stop() }
                    enabled = delegate.engine.isActive
                    delegate.updateIcon()
                }

            // Comfort level — a plain quieter ←→ louder scale, with the
            // technical LUFS figure kept as a small detail.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Comfort level")
                    Spacer()
                    Text(String(format: "%.0f LUFS", target)).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 8) {
                    Text("Quieter").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $target, in: BallastSettings.targetLoudnessRange, step: 1)
                        .onChange(of: target) { _, v in
                            BallastSettings.targetLoudness = v; delegate.engine.applySettings()
                        }
                    Text("Louder").font(.caption2).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Maximum adjustment")
                    Spacer()
                    Text(String(format: "±%.0f dB", maxGain)).foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $maxGain, in: BallastSettings.maxGainRange, step: 1)
                    .onChange(of: maxGain) { _, v in
                        BallastSettings.maxGain = v; delegate.engine.applySettings()
                    }
            }

            Text("Ballast brings every track to your comfort level — quieter tracks up, louder tracks down — so you can set the volume once and leave it. It learns each track as you listen, so the more you play, the more consistent your music becomes. \u{201C}Maximum adjustment\u{201D} caps how far it will push a track.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        PermissionSection()

        Section("Now") {
            MeterView(engine: delegate.engine)
        }

        Section("Menu Bar") {
            Toggle("Show current track title", isOn: $showTitle)
                .onChange(of: showTitle) { _, v in
                    BallastSettings.showTrackTitle = v
                    delegate.updateStatusTitle()
                }
            if showTitle {
                Stepper(value: $maxTitleLen, in: BallastSettings.maxTitleLengthRange) {
                    Text("Maximum length: \(maxTitleLen) characters")
                }
                .onChange(of: maxTitleLen) { _, v in
                    BallastSettings.maxTitleLength = v
                    delegate.updateStatusTitle()
                }
                Text("Titles longer than this are trimmed at a word boundary and end with an ellipsis. Nothing is shown while playback is paused or stopped.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        // Standard Jorvik menu-bar sections.
        MenuBarVisibilitySettings()
        MenuBarPillSettings { delegate.updateIcon() }
    }

}

/// Audio-capture (system audio recording) permission status + requester,
/// mirroring the permission section the other Jorvik menu-bar apps show.
@MainActor
private struct PermissionSection: View {
    var body: some View {
        // Re-read the (non-observable) TCC status periodically so the row
        // updates itself right after the user grants access.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = AudioCapturePermission.status
            Section("Permission") {
                LabeledContent("System audio access") {
                    switch status {
                    case .authorized:   Text("Granted").foregroundStyle(.green)
                    case .denied:       Text("Denied").foregroundStyle(.red)
                    case .undetermined: Text("Not granted").foregroundStyle(.secondary)
                    }
                }
                if status != .authorized {
                    Button(status == .denied ? "Open System Settings\u{2026}" : "Grant Access\u{2026}") {
                        if status == .denied {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                                NSWorkspace.shared.open(url)
                            }
                        } else {
                            AudioCapturePermission.request { _ in }
                        }
                    }
                }
                Text("Ballast needs permission to read the system audio mix so it can measure and level loudness. Audio is processed on-device in real time and never recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Live source-loudness and applied-gain readout, refreshed a few times a
/// second from the engine's DSP meters.
@MainActor
private struct MeterView: View {
    let engine: BallastEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let active = engine.isActive
            let source = engine.processor.meterSourceLoudness
            let gain = engine.processor.meterGainDB

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Output device") {
                    Text(engine.currentOutputDeviceName ?? "\u{2014}").foregroundStyle(.secondary)
                }
                LabeledContent("This track") {
                    Text(active && source > -100 ? String(format: "%.1f LUFS", source) : "\u{2014}")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Adjustment") {
                    Text(active ? String(format: "%+.1f dB", gain) : "\u{2014}")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                if !active {
                    Text("Turn on \u{201C}Level system audio\u{201D} to start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
