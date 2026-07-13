import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    @State private var vizMode: String
    @State private var vizOnTop: Bool
    @State private var vizColour: String
    @State private var excluded: [AppExclusions.Info]
    @State private var showResetConfirm = false
    @State private var showResetLibraryConfirm = false

    init(delegate: AppDelegate) {
        self.delegate = delegate
        _enabled = State(initialValue: delegate.engine.isActive)
        _target = State(initialValue: BallastSettings.targetLoudness)
        _maxGain = State(initialValue: BallastSettings.maxGain)
        _showTitle = State(initialValue: BallastSettings.showTrackTitle)
        _maxTitleLen = State(initialValue: BallastSettings.maxTitleLength)
        _vizMode = State(initialValue: BallastSettings.visualizerMode)
        _vizOnTop = State(initialValue: BallastSettings.visualizerKeepOnTop)
        _vizColour = State(initialValue: BallastSettings.visualizerColourSource)
        _excluded = State(initialValue: AppExclusions.excludedInfos())
    }

    private var learnedCountText: String {
        let n = delegate.engine.libraryCount
        return "\(n) \(n == 1 ? "track" : "tracks")"
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

        Section("Do Not Level") {
            if excluded.isEmpty {
                Text("Nothing excluded \u{2014} Ballast levels all system audio.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(excluded) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                        Text(app.name)
                        Spacer()
                        Button {
                            AppExclusions.remove(app.bundleID)
                            excluded = AppExclusions.excludedInfos()
                            delegate.engine.reloadExclusions()
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Level \(app.name) again")
                    }
                }
            }

            Menu("Add App\u{2026}") {
                let running = AppExclusions.addableRunningApps()
                if running.isEmpty {
                    Text("No other apps are running")
                } else {
                    ForEach(running) { app in
                        Button(app.name) { exclude(app.bundleID) }
                    }
                }
                Divider()
                Button("Choose Application\u{2026}") { chooseApplication() }
            }

            Text("Audio from these apps is left completely untouched \u{2014} handy for games, DAWs, or video calls that set their own levels. Everything else is still levelled, and changes take effect immediately.")
                .font(.caption).foregroundStyle(.secondary)
        }

        PermissionSection()

        Section("Now") {
            MeterView(engine: delegate.engine)
        }

        Section("Library") {
            LabeledContent("Learned") {
                Text(learnedCountText).foregroundStyle(.secondary).monospacedDigit()
            }

            Button("Reset Play Counts & Love\u{2026}", role: .destructive) {
                showResetConfirm = true
            }
            .alert("Reset play counts & love?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) { delegate.engine.resetPlayStats() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every track\u{2019}s play count and \u{201C}love\u{201D} rating returns to zero. The learned loudness is kept, so levelling is unaffected. This can\u{2019}t be undone.")
            }

            Button("Reset Learned Library\u{2026}", role: .destructive) {
                showResetLibraryConfirm = true
            }
            .alert("Reset the learned library?", isPresented: $showResetLibraryConfirm) {
                Button("Reset", role: .destructive) { delegate.engine.resetLibrary() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Ballast will forget every learned track \u{2014} loudness, play counts and ratings \u{2014} and relearn your music from scratch as you listen. This can\u{2019}t be undone.")
            }

            Text("\u{201C}Reset Play Counts\u{201D} clears the listening stats but keeps every track\u{2019}s learned level. \u{201C}Reset Learned Library\u{201D} forgets everything and starts levelling from scratch.")
                .font(.caption).foregroundStyle(.secondary)
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

        Section("Visualiser") {
            Picker("Style", selection: $vizMode) {
                ForEach(VisualizerMode.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m.rawValue)
                }
            }
            .onChange(of: vizMode) { _, v in
                BallastSettings.visualizerMode = v; delegate.visualizer.applySettings()
            }
            Toggle("Keep window on top", isOn: $vizOnTop)
                .onChange(of: vizOnTop) { _, v in
                    BallastSettings.visualizerKeepOnTop = v; delegate.visualizer.applySettings()
                }
            Picker("Colour", selection: $vizColour) {
                ForEach(VisualizerColourSource.allCases, id: \.self) { c in
                    Text(c.displayName).tag(c.rawValue)
                }
            }
            .onChange(of: vizColour) { _, v in
                BallastSettings.visualizerColourSource = v; delegate.visualizer.applySettings()
            }
            Button("Open Visualiser\u{2026}") { delegate.visualizer.show() }
            Text("A real-time visualiser of whatever's playing, in a chromeless resizable window. Right-click it to switch styles, keep it on top, or go full-screen; the arrow keys cycle styles.")
                .font(.caption).foregroundStyle(.secondary)
        }

        // Standard Jorvik menu-bar sections.
        MenuBarVisibilitySettings()
        MenuBarPillSettings { delegate.updateIcon() }
    }

    private func exclude(_ bundleID: String) {
        AppExclusions.add(bundleID)
        excluded = AppExclusions.excludedInfos()
        delegate.engine.reloadExclusions()
    }

    /// Browse for an app that isn't currently running (so it's not in the menu).
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "Choose an app whose audio Ballast should leave untouched."
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { return }
        exclude(bid)
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

                let auto = AutomationPermission.combined
                LabeledContent("Music & Spotify") {
                    switch auto {
                    case .authorized:   Text("Granted").foregroundStyle(.green)
                    case .denied:       Text("Denied").foregroundStyle(.red)
                    case .notRunning:   Text("\u{2014}").foregroundStyle(.secondary)
                    case .undetermined: Text("Not requested").foregroundStyle(.secondary)
                    }
                }
                if auto == .denied {
                    Button("Open System Settings\u{2026}") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Text("Optional. Lets Ballast apply the currently-playing track's level the instant you switch levelling on, by reading what Music or Spotify is playing. Without it, it waits for the next track change.")
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
