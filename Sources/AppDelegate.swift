import AppKit
import SwiftUI
import ServiceManagement
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    let engine = BallastEngine()
    let visualizer = VisualizerController()
    let sparkleUserDriverDelegate = BallastUserDriverDelegate()
    lazy var sparkleUpdater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: sparkleUserDriverDelegate
    )

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        BallastSettings.registerDefaults()

        // Refresh the icon/menu whenever the engine's state changes — including
        // after the asynchronous audio-capture permission grant.
        engine.stateDidChange = { [weak self] in self?.updateIcon() }
        engine.trackDidChange = { [weak self] in self?.updateStatusTitle() }
        visualizer.engine = engine

        createStatusItem()
        _ = sparkleUpdater  // forces lazy init so Sparkle starts at launch

        // Resume levelling if it was on when the app last quit. Starting here
        // (rather than defaulting on) means a fresh install stays inert until
        // the user opts in — which is also when macOS prompts for the
        // audio-capture permission.
        if BallastSettings.isEnabled {
            engine.start()
            updateIcon()
        } else {
            // First launch (or never enabled): show the one-time welcome panel.
            BallastOnboarding.showIfNeeded { [weak self] in
                self?.engine.start()
                self?.updateIcon()
            }
        }

        // Redraw the status icon when the display configuration changes — the
        // menu bar's effective thickness can shrink and leave a pre-rendered
        // pill cropped.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }

        // Create or remove the status item when the user toggles its
        // visibility in Settings.
        NotificationCenter.default.addObserver(
            forName: JorvikStatusItemVisibility.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyStatusItemVisibility() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Leave BallastSettings.isEnabled as-is so state resumes next launch,
        // but tear the graph down cleanly so the tap's mute is lifted.
        let wasEnabled = BallastSettings.isEnabled
        engine.stop()
        BallastSettings.isEnabled = wasEnabled
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        JorvikStatusItemVisibility.handleReopen()
        return true
    }

    // MARK: - Status item

    private static let statusItemAutosaveName = "BallastMenuBarItem"

    func createStatusItem() {
        guard JorvikStatusItemVisibility.isVisible else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.autosaveName = Self.statusItemAutosaveName
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    func applyStatusItemVisibility() {
        if JorvikStatusItemVisibility.isVisible {
            if statusItem == nil { createStatusItem() }
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Icon

    func updateIcon() {
        // A waveform reads as "audio"; the slashed variant signals levelling is
        // paused. Fall back to the plain waveform if the slash symbol is
        // unavailable on this OS.
        let symbolName = engine.isActive ? "waveform" : "waveform.slash"
        let image = JorvikMenuBarPill.icon(symbolName: symbolName, accessibilityDescription: "Ballast")
            ?? JorvikMenuBarPill.icon(symbolName: "waveform", accessibilityDescription: "Ballast")
        statusItem?.button?.image = image
        updateStatusTitle()
    }

    /// Shows the current track title to the right of the icon when enabled and
    /// a track is actually playing; icon-only otherwise (no track, paused, or
    /// title display off).
    func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        if BallastSettings.showTrackTitle, engine.isActive, engine.isPlaying,
           let raw = engine.currentTrackTitle, !raw.isEmpty {
            button.title = " " + Self.truncateTitle(raw, max: BallastSettings.maxTitleLength)
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    /// Truncate to `max` grapheme clusters at the nearest whitespace to the
    /// left of the limit, then append an ellipsis. UTF-8 / emoji safe (it
    /// counts Characters, not bytes). If the first word alone exceeds the
    /// limit, it hard-cuts at `max`.
    static func truncateTitle(_ title: String, max: Int) -> String {
        guard title.count > max else { return title }
        let prefix = title.prefix(max)
        if let wsIndex = prefix.lastIndex(where: { $0.isWhitespace }) {
            var head = prefix[..<wsIndex]
            while let last = head.last, last.isWhitespace { head = head.dropLast() }
            if !head.isEmpty { return String(head) + "\u{2026}" }
        }
        return String(prefix) + "\u{2026}"
    }

    // MARK: - Dynamic menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateIcon()

        var actions: [JorvikMenuBuilder.ActionItem] = []

        actions.append(JorvikMenuBuilder.ActionItem(
            title: "Level Loudness",
            action: #selector(toggleLevelling),
            target: self,
            state: engine.isActive ? .on : .off
        ))

        // Live level stats now live in the visualiser's Now Playing mode (and
        // Settings → Now), so the menu stays controls-only.
        if engine.isActive {
            actions.append(JorvikMenuBuilder.ActionItem(
                title: "Re-level Now",
                action: #selector(relevelNow),
                target: self
            ))
            actions.append(JorvikMenuBuilder.ActionItem(
                title: "Visualiser\u{2026}",
                action: #selector(openVisualizer),
                target: self
            ))
        }

        actions.append(JorvikMenuBuilder.ActionItem(title: "-", action: #selector(noop), target: self))
        actions.append(JorvikMenuBuilder.ActionItem(
            title: "Check for Updates\u{2026}",
            action: #selector(checkForUpdates(_:)),
            target: self
        ))

        let built = JorvikMenuBuilder.buildMenu(
            appName: "Ballast",
            aboutAction: #selector(openAbout),
            settingsAction: #selector(openSettings),
            target: self,
            actions: actions
        )

        menu.removeAllItems()
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }

    }


    // MARK: - Actions

    @objc private func toggleLevelling() {
        if engine.isActive {
            engine.stop()
        } else {
            engine.start()
        }
        updateIcon()
    }

    @objc private func relevelNow() {
        engine.relevelNow()
    }

    @objc private func openVisualizer() {
        visualizer.toggle()
    }

    @objc private func noop() {}

    @objc func checkForUpdates(_ sender: Any?) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        sparkleUpdater.checkForUpdates(sender)
    }

    // MARK: - About & Settings

    @objc private func openAbout() {
        JorvikAboutView.showWindow(
            appName: "Ballast",
            repoName: "Ballast",
            productPage: "utilities/ballast"
        )
    }

    @objc private func openSettings() {
        let delegate = self
        JorvikSettingsView.showWindow(appName: "Ballast") {
            BallastSettingsContent(delegate: delegate)
        }
    }
}

/// Keeps Sparkle's update UI visible across the whole session, including when
/// the user switches to another app mid-download. Mirrors the shared
/// `JorvikUserDriverDelegate`; inlined per the catalogue's convention.
final class BallastUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    private var sessionObserver: NSObjectProtocol?
    private var elevatedWindows: [(window: NSWindow, originalLevel: NSWindow.Level)] = []

    func standardUserDriverWillShowModalAlert() {
        bringForward()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        startFocusGuard()
        bringForward()
    }

    func standardUserDriverWillFinishUpdateSession() {
        stopFocusGuard()
    }

    private func bringForward() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        elevateAllWindows()
    }

    private func startFocusGuard() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringForward()
        }
    }

    private func stopFocusGuard() {
        if let obs = sessionObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionObserver = nil
        }
        for entry in elevatedWindows {
            entry.window.level = entry.originalLevel
        }
        elevatedWindows.removeAll()
    }

    private func elevateAllWindows() {
        for window in NSApp.windows where window.isVisible && window.level == .normal {
            elevatedWindows.append((window, window.level))
            window.level = .floating
        }
    }
}
