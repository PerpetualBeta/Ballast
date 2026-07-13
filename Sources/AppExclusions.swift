import AppKit

/// The apps the user has chosen NOT to level — games, DAWs, video calls: things
/// with their own carefully-set dynamics that Ballast's system-wide tap would
/// otherwise flatten. (The tap is global; it can exclude specific processes.)
///
/// We persist stable **bundle identifiers**, but Core Audio excludes by *process*,
/// so bundle IDs are resolved to the running PIDs at tap-build time — and the
/// engine rebuilds the tap when an excluded app launches or quits, so a
/// freshly-launched excluded app is caught without the user lifting a finger.
enum AppExclusions {

    /// Persisted bundle identifiers, in the order the user added them.
    static var bundleIDs: [String] {
        get { BallastSettings.excludedBundleIDs }
        set { BallastSettings.excludedBundleIDs = newValue }
    }

    static func add(_ bundleID: String) {
        var ids = bundleIDs
        guard !ids.contains(bundleID) else { return }
        ids.append(bundleID)
        bundleIDs = ids
    }

    static func remove(_ bundleID: String) {
        bundleIDs = bundleIDs.filter { $0 != bundleID }
    }

    static func contains(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }

    /// PIDs of every currently-running instance of an excluded app. Empty when
    /// none of the excluded apps are running (nothing to keep off the tap yet).
    static func runningPIDs() -> [pid_t] {
        let excluded = Set(bundleIDs)
        guard !excluded.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications
            .filter { excluded.contains($0.bundleIdentifier ?? "") }
            .map(\.processIdentifier)
    }

    // MARK: Display

    struct Info: Identifiable {
        let bundleID: String
        let name: String
        let icon: NSImage
        var id: String { bundleID }
    }

    private static var genericIcon: NSImage {
        NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
    }

    /// Icon + display name for a persisted bundle ID, whether or not it's running.
    static func info(for bundleID: String) -> Info {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return Info(bundleID: bundleID, name: app.localizedName ?? bundleID, icon: app.icon ?? genericIcon)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return Info(bundleID: bundleID,
                        name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                        icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        return Info(bundleID: bundleID, name: bundleID, icon: genericIcon)
    }

    /// The persisted exclusions, resolved for display, in saved order.
    static func excludedInfos() -> [Info] { bundleIDs.map(info(for:)) }

    /// Running, ordinary (Dock-visible) apps that could be added — excluding
    /// Ballast itself and anything already excluded — de-duplicated by bundle ID
    /// and sorted by name. The quick "exclude what's already running" picker.
    static func addableRunningApps() -> [Info] {
        let already = Set(bundleIDs)
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var out: [Info] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier, bid != me, !already.contains(bid), seen.insert(bid).inserted
            else { continue }
            out.append(Info(bundleID: bid, name: app.localizedName ?? bid, icon: app.icon ?? genericIcon))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
