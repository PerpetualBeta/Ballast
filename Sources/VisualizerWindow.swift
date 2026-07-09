import AppKit
import MetalKit

/// Borderless panel that can still take key events (for keyboard mode control).
final class VisualizerPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// MTKView that forwards keyboard + right-click to the controller.
final class VisualizerMetalView: MTKView {
    weak var controller: VisualizerController?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: controller?.cycleMode(-1)      // left arrow
        case 124: controller?.cycleMode(1)       // right arrow
        case 53:  controller?.hide()             // esc
        case 3:   controller?.toggleFullScreen() // f
        default:  super.keyDown(with: event)
        }
    }
}

/// Owns the chromeless, resizable, drag-anywhere visualiser window and its
/// Metal renderer. The audio feed only runs while this window is visible.
@MainActor
final class VisualizerController: NSObject, NSWindowDelegate, NSMenuDelegate {

    private var window: VisualizerPanel?
    private var renderer: VisualizerRenderer?
    private var metalView: VisualizerMetalView?
    private var vuView: VUMeterView?
    private var container: NSView?
    private var flashLabel: NSTextField?
    private var savedFrame: NSRect?
    private var isFullScreen = false

    var isOpen: Bool { window?.isVisible ?? false }

    func toggle() { isOpen ? hide() : show() }

    func show() {
        if window == nil { build() }
        guard let window, let metalView else { return }
        VisualizerFeed.shared.active.store(true, ordering: .relaxed)
        applyKeepOnTop()
        refreshPalette()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(metalView)
        NSApp.activate(ignoringOtherApps: true)
        updateModeVisibility()
        flashMode()
    }

    func hide() {
        VisualizerFeed.shared.active.store(false, ordering: .relaxed)
        vuView?.stop()
        window?.orderOut(nil)
    }

    func applySettings() {
        if let m = VisualizerMode(rawValue: BallastSettings.visualizerMode) { renderer?.mode = m }
        applyKeepOnTop()
        refreshPalette()
        updateModeVisibility()
        flashMode()
    }

    private func updateModeVisibility() {
        let isVU = (renderer?.mode == .vu)
        vuView?.isHidden = !isVU
        metalView?.isHidden = isVU
        if isVU { vuView?.start() } else { vuView?.stop() }
        window?.makeFirstResponder(isVU ? vuView : metalView)
    }

    func refreshPalette() {
        let source = VisualizerColourSource(rawValue: BallastSettings.visualizerColourSource) ?? .builtin
        renderer?.colours = WallpaperPalette.colours(source: source, screen: window?.screen)
    }

    // MARK: Build

    private func build() {
        let mode = VisualizerMode(rawValue: BallastSettings.visualizerMode) ?? .aurora
        guard let r = VisualizerRenderer(mode: mode) else {
            blLog("visualiser: renderer init failed"); return
        }
        renderer = r

        let frame = NSRect(x: 0, y: 0, width: 720, height: 405)
        let view = VisualizerMetalView(frame: frame, device: r.device)
        view.colorPixelFormat = MTLPixelFormat.bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.delegate = r
        view.controller = self
        view.autoresizingMask = [.width, .height]
        metalView = view

        let box = NSView(frame: frame)
        view.frame = box.bounds
        box.addSubview(view)
        let vu = VUMeterView(frame: box.bounds)
        vu.autoresizingMask = [.width, .height]
        vu.isHidden = true
        box.addSubview(vu)
        vuView = vu
        container = box

        // A titled window with its title bar + traffic lights hidden and content
        // extended full-size: looks chromeless, but macOS supplies its own
        // standard window corner radius (uniform across the OS, incl. Golden Gate)
        // instead of us hardcoding one.
        let w = VisualizerPanel(contentRect: frame,
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        w.contentView = box
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.collectionBehavior = [.fullScreenNone]
        w.delegate = self
        w.setFrameAutosaveName("BallastVisualizerWindow")
        if !w.setFrameUsingName("BallastVisualizerWindow") { w.center() }
        window = w

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alphaValue = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
        ])
        flashLabel = label

        let menu = NSMenu()
        menu.delegate = self
        view.menu = menu
        vu.menu = menu
        vu.controller = self

        // Re-derive the wallpaper palette when the desktop (or Space) changes.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refreshPalette() } }
        refreshPalette()
    }

    // MARK: Modes

    func cycleMode(_ direction: Int) {
        let all = VisualizerMode.allCases
        guard let r = renderer, let idx = all.firstIndex(of: r.mode) else { return }
        setMode(all[(idx + direction + all.count) % all.count])
    }

    func setMode(_ mode: VisualizerMode) {
        renderer?.mode = mode
        BallastSettings.visualizerMode = mode.rawValue
        updateModeVisibility()
        flashMode()
    }

    private func flashMode() {
        guard let label = flashLabel, let r = renderer, isOpen else { return }
        label.stringValue = r.mode.displayName
        label.alphaValue = 1
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fadeLabel), object: nil)
        perform(#selector(fadeLabel), with: nil, afterDelay: 1.3)
    }
    @objc private func fadeLabel() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            flashLabel?.animator().alphaValue = 0
        }
    }

    // MARK: Window level / full screen

    private func applyKeepOnTop() {
        guard !isFullScreen else { return }
        window?.level = BallastSettings.visualizerKeepOnTop ? .floating : .normal
    }

    func toggleFullScreen() {
        guard let w = window, let screen = w.screen ?? NSScreen.main else { return }
        if isFullScreen {
            isFullScreen = false
            if let f = savedFrame { w.setFrame(f, display: true) }
            applyKeepOnTop()
        } else {
            savedFrame = w.frame
            isFullScreen = true
            w.level = .screenSaver
            w.setFrame(screen.frame, display: true)
        }
    }

    // MARK: Context menu (NSMenuDelegate)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for m in VisualizerMode.allCases {
            let item = NSMenuItem(title: m.displayName, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.rawValue
            item.state = (renderer?.mode == m) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let top = NSMenuItem(title: "Keep on Top", action: #selector(toggleTop), keyEquivalent: "")
        top.target = self
        top.state = BallastSettings.visualizerKeepOnTop ? .on : .off
        menu.addItem(top)
        let fs = NSMenuItem(title: isFullScreen ? "Exit Full Screen" : "Full Screen",
                            action: #selector(fullScreenAction), keyEquivalent: "")
        fs.target = self
        menu.addItem(fs)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Visualiser", action: #selector(closeAction), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = VisualizerMode(rawValue: raw) { setMode(m) }
    }
    @objc private func toggleTop() { BallastSettings.visualizerKeepOnTop.toggle(); applyKeepOnTop() }
    @objc private func fullScreenAction() { toggleFullScreen() }
    @objc private func closeAction() { hide() }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        VisualizerFeed.shared.active.store(false, ordering: .relaxed)
    }
}
