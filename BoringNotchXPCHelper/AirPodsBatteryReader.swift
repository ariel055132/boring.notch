import Foundation
import CoreFoundation

struct AirPodsBatteryReader: Sendable {
    func read() async -> DeviceBatterySourceResult {
        do {
            let data = try await DeviceBatteryProcess(
                executable: URL(fileURLWithPath: "/usr/sbin/system_profiler"),
                arguments: ["SPBluetoothDataType", "-json"]
            ).run()
            return try Self.parseSystemReport(data, at: Date())
        } catch {
            return .init(source: .airPods, state: error as? DeviceBatterySourceState ?? .unavailable)
        }
    }

    static func parseSystemReport(_ data: Data, at date: Date) throws -> DeviceBatterySourceResult {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else {
            throw DeviceBatterySourceState.invalidResponse
        }
        guard !controllers.isEmpty else { return .init(source: .airPods, state: .unavailable) }
        var devices: [String: DeviceBatterySnapshot] = [:]
        var foundController = false
        var enabled = false
        for controller in controllers {
            if let properties = controller["controller_properties"] as? [String: Any],
               let state = properties["controller_state"] as? String,
               state == "attrib_on" || state == "attrib_off" {
                foundController = true
                enabled = enabled || state == "attrib_on"
            }
            guard let entries = controller["device_connected"] as? [[String: Any]] else { continue }
            for entry in entries {
                for (name, value) in entry {
                    guard let info = value as? [String: Any], isAirPods(info),
                          let address = info["device_address"] as? String, !address.isEmpty else { continue }
                    let id = "airpods:" + address.uppercased().replacingOccurrences(of: "-", with: ":")
                    let keys: [(BatteryComponent, String)] = [(.left, "device_batteryLevelLeft"),
                        (.right, "device_batteryLevelRight"), (.chargingCase, "device_batteryLevelCase"),
                        (.main, "device_batteryLevelMain")]
                    let components = keys.compactMap { component, key -> BatteryComponentReading? in
                        guard let percent = percentage(info[key]) else { return nil }
                        return .init(component: component, percent: percent, readAt: date,
                                     provenance: .systemCache)
                    }
                    devices[id] = .init(id: id, name: name, kind: .airPods,
                                        connectionState: .connected, components: components)
                }
            }
        }
        if !devices.isEmpty { return .init(source: .airPods, state: .available, devices: Array(devices.values)) }
        return .init(source: .airPods, state: foundController ? (enabled ? .noDevices : .bluetoothOff) : .unavailable)
    }

    private static func isAirPods(_ info: [String: Any]) -> Bool {
        guard (info["device_vendorID"] as? String)?.lowercased() == "0x004c" else { return false }
        let products: Set<String> = ["0x2002", "0x200a", "0x200e", "0x200f", "0x2013", "0x2014",
                                     "0x201e", "0x201f", "0x2024", "0x2025"]
        return products.contains((info["device_productID"] as? String)?.lowercased() ?? "")
    }

    static func percentage(_ value: Any?) -> Int? {
        let number: Int?
        if let string = value as? String {
            number = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: ""))
        } else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue {
            number = (0...100).contains(n.doubleValue) ? n.intValue : nil
        } else { number = nil }
        guard let number, (0...100).contains(number) else { return nil }
        return number
    }
}
