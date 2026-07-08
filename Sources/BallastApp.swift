import SwiftUI

@main
struct BallastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Ballast lives entirely in the menu bar; the status item and its menu
        // are created by AppDelegate. The Settings scene is intentionally empty
        // — "Settings…" opens a JorvikSettingsView window imperatively.
        Settings { EmptyView() }
    }
}
