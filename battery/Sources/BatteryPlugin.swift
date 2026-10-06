import Foundation
import IOKit.ps
import IslandKit

/// Battery levels of the Mac and of connected Bluetooth devices (AirPods, Magic Mouse, Keyboard and Trackpad),
/// with a popup when one runs low or the Mac starts charging, and the low one beside the notch
@main
struct BatteryPlugin: IslandPlugin {
    static let id = "battery"
    static let name = "Battery"
    static let symbol = "battery.75percent"
    static let version = "1.0.0"
    static let description: String? = "The Mac's and Bluetooth devices' batteries, with a popup when one runs low"
    /// Warns of a low battery with its tab hidden too
    static let background = true

    @Preference("Warn at or below (%)", options: [10, 15, 20, 30]) var threshold = 20
    @Preference("Show the Mac's battery") var includeMac = true
    @Preference("Popup when the Mac starts charging") var chargingPopup = true

    @State var batteries: [Battery] = []
    @State var updated: Date? = nil
    /// Devices already warned about, until they charge or rise above the threshold again
    @State var warned: [String] = []
    @State var macCharging: Bool? = nil

    /// The power source callback can't hold a context, so it reaches the plugin through this
    static var powerChanged: (@MainActor () -> Void)?

    var body: some IslandContent {
        if let low = shown.filter({ isLow($0) }).min(by: { $0.level < $1.level }) {
            Compact(symbol: low.symbol, text: "\(low.level)%", progress: Double(low.level) / 100)
        }

        for battery in shown {
            Row(battery.name, subtitle: subtitle(battery), symbol: battery.symbol, id: battery.id)
        }
        if shown.isEmpty, updated != nil {
            Row("No batteries found", subtitle: "Connect AirPods, a Magic Mouse, Keyboard or Trackpad", symbol: "battery.0percent")
        }

        Button("Refresh", symbol: "arrow.clockwise") { refresh(bluetooth: true) }
    }

    var shown: [Battery] {
        batteries.filter { includeMac || !$0.isMac }
    }

    func isLow(_ battery: Battery) -> Bool {
        !battery.charging && battery.level <= threshold
    }

    func subtitle(_ battery: Battery) -> String {
        var parts = battery.parts ?? ["\(battery.level)%"]
        if let state = battery.state { parts.append(state) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Reading

    func onStart() {
        Self.powerChanged = { refresh(bluetooth: false) }
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { BatteryPlugin.powerChanged?() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        // Bluetooth devices report their levels only now and then: every 30 seconds while the tab shows, else every 2 minutes
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                let due = updated.map { Island.now.timeIntervalSince($0) >= 115 } ?? true
                if Island.isTabVisible || due { refresh(bluetooth: true) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refresh(bluetooth: true)
    }

    /// Reads the Mac's battery at once, and Bluetooth devices (a slower read) when `bluetooth`
    func refresh(bluetooth: Bool) {
        if !bluetooth {
            apply(BatteryReader.powerSources() + batteries.filter { !$0.isPowerSource })
            return
        }
        Task {
            let found = await Task.detached { BatteryReader.powerSources() + BatteryReader.bluetoothDevices() }.value
            apply(found)
            updated = Island.now
        }
    }

    func apply(_ found: [Battery]) {
        batteries = found
        warnIfNeeded()
    }

    /// One popup per device as it drops to the threshold, and one when the Mac starts charging
    func warnIfNeeded() {
        for battery in shown where isLow(battery) && !warned.contains(battery.id) {
            warned.append(battery.id)
            Island.popup("\(battery.name) \(battery.level)%", symbol: "battery.25percent", seconds: 4)
        }
        warned.removeAll { id in
            guard let battery = batteries.first(where: { $0.id == id }) else { return false }
            return battery.charging || battery.level > threshold + 5
        }

        if let mac = batteries.first(where: \.isMac) {
            if chargingPopup, includeMac, macCharging == false, mac.charging {
                let charging = mac.state?.hasPrefix("Charging") ?? false
                Island.popup("\(charging ? "Charging" : "Plugged in"), \(mac.level)%", symbol: "bolt.fill", seconds: 3)
            }
            macCharging = mac.charging
        }
    }
}

/// One battery, or a device with several (AirPods: each bud and the case)
struct Battery: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// The lowest of its parts, 0 to 100
    var level: Int
    var charging = false
    /// "Charging", "2:10 left"
    var state: String? = nil
    /// "Left 80%", "Right 75%", "Case 40%"
    var parts: [String]? = nil
    var symbol: String
    var isMac = false
    /// Read through the power sources, which tell when they change; the rest are polled
    var isPowerSource = false
}

/// Reads batteries: power sources (the Mac's, some accessories) through IOKit, Bluetooth devices through
/// system_profiler, and Apple's own keyboards, mice and trackpads through their HID services
enum BatteryReader {
    static func powerSources() -> [Battery] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return list.compactMap { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSIsPresentKey] as? Bool ?? true,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
            let level = min(100, current * 100 / maximum)
            let isMac = description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            let onPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let name = isMac ? "This Mac" : (description[kIOPSNameKey] as? String ?? "Battery")

            var state: String?
            if description[kIOPSIsChargedKey] as? Bool == true || (onPower && !charging && level >= 99) {
                state = "Charged"
            } else if charging {
                let minutes = description[kIOPSTimeToFullChargeKey] as? Int ?? -1
                state = minutes > 0 ? "Charging, \(duration(minutes)) to full" : "Charging"
            } else if onPower {
                state = "On power, not charging"
            } else if isMac {
                let minutes = description[kIOPSTimeToEmptyKey] as? Int ?? -1
                state = minutes > 0 ? "\(duration(minutes)) left" : nil
            }
            return Battery(id: isMac ? "mac" : "source-\(name)", name: name, level: level, charging: charging || onPower,
                           state: state, symbol: isMac ? "laptopcomputer" : symbol(for: name, type: nil),
                           isMac: isMac, isPowerSource: true)
        }
    }

    /// Connected Bluetooth devices that report a battery, then Apple's HID ones system_profiler left out
    static func bluetoothDevices() -> [Battery] {
        var found = systemProfilerDevices()
        for device in hidDevices() where !found.contains(where: { sameDevice($0.name, device.name) }) {
            found.append(device)
        }
        return found
    }

    private static func systemProfilerDevices() -> [Battery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        let devices = controllers.flatMap { $0["device_connected"] as? [[String: [String: Any]]] ?? [] }
        return devices.flatMap { $0 }.compactMap { name, properties in
            let levels: [(part: String, key: String)] = [("Left", "device_batteryLevelLeft"), ("Right", "device_batteryLevelRight"),
                                                          ("Case", "device_batteryLevelCase"), ("", "device_batteryLevelMain")]
            let parts = levels.compactMap { part, key in percent(properties[key]).map { (part, $0) } }
            guard !parts.isEmpty else { return nil }
            // The case only matters once the buds are low; the level is the lowest bud's, or the case's alone
            let buds = parts.filter { $0.0 != "Case" }
            let level = (buds.isEmpty ? parts : buds).map(\.1).min() ?? 0
            let labels = parts.count > 1 ? parts.map { $0.0.isEmpty ? "\($0.1)%" : "\($0.0) \($0.1)%" } : nil
            let address = properties["device_address"] as? String ?? name
            return Battery(id: "bt-\(address)", name: name, level: level, parts: labels,
                           symbol: symbol(for: name, type: properties["device_minorType"] as? String))
        }
    }

    /// Apple keyboards, mice and trackpads report BatteryPercent on their HID event service
    private static func hidDevices() -> [Battery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [Battery] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let level = property("BatteryPercent") as? Int, let name = property("Product") as? String else { continue }
            let charging = (property("BatteryStatusFlags") as? Int).map { $0 & 0x2 != 0 } ?? false
            found.append(Battery(id: "hid-\(property("SerialNumber") as? String ?? name)", name: name, level: level,
                                 charging: charging, state: charging ? "Charging" : nil, symbol: symbol(for: name, type: nil)))
        }
        return found
    }

    /// "80%" or 80
    private static func percent(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        guard let text = value as? String else { return nil }
        return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
    }

    /// One device seen twice under slightly different names ("Magic Mouse", "Joey's Magic Mouse")
    private static func sameDevice(_ first: String, _ second: String) -> Bool {
        let first = first.lowercased(), second = second.lowercased()
        return first.contains(second) || second.contains(first)
    }

    static func symbol(for name: String, type: String?) -> String {
        let name = name.lowercased(), type = type?.lowercased() ?? ""
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if name.contains("mouse") || type.contains("mouse") { return "magicmouse" }
        if name.contains("keyboard") || type.contains("keyboard") { return "keyboard" }
        if type.contains("headphone") || type.contains("headset") || name.contains("beats") { return "headphones" }
        if type.contains("speaker") { return "hifispeaker" }
        if type.contains("gamepad") || type.contains("joystick") || name.contains("controller") { return "gamecontroller" }
        return "battery.50percent"
    }

    /// "2:05" from minutes
    private static func duration(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
