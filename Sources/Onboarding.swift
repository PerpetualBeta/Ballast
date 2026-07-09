import SwiftUI
import AppKit

/// A one-time welcome panel shown on first launch, explaining what Ballast does
/// and priming the (non-obvious) audio-capture permission before it's requested.
@MainActor
struct BallastOnboardingView: View {
    let onEnable: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 72, height: 72)
            }
            Text("Welcome to Ballast").font(.title2).bold()
            Text("Ballast keeps every track at a comfortable level and learns your music — a quiet track and a loud one land in the same place, so you can set the volume once and leave it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Label("It reads your system audio to measure loudness.", systemImage: "waveform")
                Label("Everything is processed on-device, in real time — never recorded or sent anywhere.", systemImage: "lock.shield")
                Label("When you enable it, macOS asks for audio-capture permission — that's expected. Click Allow.", systemImage: "checkmark.seal")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Maybe Later") { onLater() }
                Spacer()
                Button("Enable Levelling") { onEnable() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 440)
    }
}

@MainActor
enum BallastOnboarding {
    private static var window: NSWindow?

    /// Show the welcome panel once. `enable` is invoked if the user chooses to
    /// turn levelling on from it.
    static func showIfNeeded(enable: @escaping () -> Void) {
        guard !BallastSettings.hasCompletedOnboarding else { return }

        let view = BallastOnboardingView(
            onEnable: {
                BallastSettings.hasCompletedOnboarding = true
                close()
                enable()
            },
            onLater: {
                BallastSettings.hasCompletedOnboarding = true
                close()
            }
        )
        let controller = NSHostingController(rootView: view)
        controller.view.layoutSubtreeIfNeeded()

        let win = NSWindow(contentViewController: controller)
        win.title = "Welcome to Ballast"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.setContentSize(controller.view.fittingSize)
        JorvikWindowHelper.centreOnActiveDisplay(win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private static func close() {
        window?.close()
        window = nil
    }
}
