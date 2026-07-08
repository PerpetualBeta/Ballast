import Foundation

// Diagnostic logging — off by default, enabled per-machine via:
//   defaults write cc.jorviksoftware.Ballast debugLogging -bool YES
//   defaults delete cc.jorviksoftware.Ballast debugLogging   # turn off
// When on, timestamped lines are appended to
//   ~/Library/Logs/Ballast/ballast.log
//
// Never write to Console/stderr or /tmp. This mirrors the Jorvik logging
// convention (Rainy Day/App/Log.swift): a symlink-safe append to a 0700
// directory, gated behind a UserDefaults flag read on every call.
private let blLogPath: String = {
    let logs = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("Ballast", isDirectory: true)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    return logs.appendingPathComponent("ballast.log").path
}()
private let blLogQueue = DispatchQueue(label: "cc.jorviksoftware.Ballast.log")
private let blLogFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func blLog(_ msg: String) {
    guard UserDefaults.standard.bool(forKey: "debugLogging") else { return }
    let line = "\(blLogFmt.string(from: Date()))  \(msg)\n"
    blLogQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        // O_NOFOLLOW + 0700 parent dir closes the symlink-attack vector.
        let fd = open(blLogPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }
}
