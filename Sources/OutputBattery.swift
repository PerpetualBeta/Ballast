import CoreAudio
import Foundation

/// Resolves the battery charge of the current output device when that device is
/// a battery-powered Bluetooth output (wireless headphones, earbuds, speakers).
/// Returns nil for wired/built-in/AirPlay outputs, or for a Bluetooth device
/// that simply doesn't report a battery.
///
/// macOS only surfaces Bluetooth battery through `system_profiler`; the Core
/// Audio HAL and the public IOBluetooth API don't expose it for A2DP audio
/// devices. So we shell out — but sparingly, and only once we've confirmed via
/// the HAL that the output is actually Bluetooth, so the common built-in case
/// costs a single cheap property read and never spawns a process.
enum OutputBattery {

    /// Battery percentage (0–100) of the current output device, or nil.
    static func currentOutputBattery() -> Int? {
        guard let dev = CoreAudioSupport.defaultOutputDevice(),
              let transport = CoreAudioSupport.deviceTransportType(dev),
              transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
        else { return nil }

        let uidHex = hexOnly(CoreAudioSupport.deviceUID(dev) ?? "")
        let name = CoreAudioSupport.deviceName(dev)
        return batteryFromSystemProfiler(addressHex: uidHex, deviceName: name)
    }

    // MARK: system_profiler

    private static func batteryFromSystemProfiler(addressHex: String, deviceName: String?) -> Int? {
        guard let data = runSystemProfiler(),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return nil }

        for controller in controllers {
            // Battery is only meaningful for a currently-connected device.
            guard let connected = controller["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, raw) in entry {
                    guard let props = raw as? [String: Any] else { continue }
                    // Match the HAL device to its Bluetooth entry by MAC (the
                    // Core Audio UID embeds the address) or, failing that, by
                    // name — a Bluetooth audio device's Core Audio name is its
                    // Bluetooth name verbatim.
                    let addr = hexOnly(props["device_address"] as? String ?? "")
                    let addrMatch = !addr.isEmpty && !addressHex.isEmpty && addressHex.contains(addr)
                    let nameMatch = deviceName != nil && name == deviceName
                    guard addrMatch || nameMatch else { continue }
                    if let level = batteryLevel(props) { return level }
                }
            }
        }
        return nil
    }

    /// Reduce a device's reported cells to a single figure: prefer the single
    /// "main" level; for earbuds with separate cells, report the lower of the
    /// two (the one that will die first); fall back to the case.
    private static func batteryLevel(_ props: [String: Any]) -> Int? {
        func pct(_ key: String) -> Int? {
            guard let s = props[key] as? String else { return nil }
            return Int(s.filter { $0.isNumber })
        }
        if let main = pct("device_batteryLevelMain") { return main }
        let left = pct("device_batteryLevelLeft"), right = pct("device_batteryLevelRight")
        if let left, let right { return min(left, right) }
        return left ?? right ?? pct("device_batteryLevelCase")
    }

    private static func runSystemProfiler() -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        // Drain before waiting: reading to EOF avoids the 64 KB pipe-buffer
        // deadlock a large device list could otherwise hit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return data.isEmpty ? nil : data
    }

    private static func hexOnly(_ s: String) -> String {
        String(s.uppercased().filter(\.isHexDigit))
    }
}
