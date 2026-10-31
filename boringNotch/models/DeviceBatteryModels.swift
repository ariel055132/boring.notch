import Foundation

enum DeviceKind: String, Codable, Sendable, CaseIterable { case airPods }
enum BatteryComponent: String, Codable, Sendable, CaseIterable { case main, left, right, chargingCase }
enum ChargingState: String, Codable, Sendable { case charging, notCharging, unknown }
enum ConnectionState: String, Codable, Sendable { case connected, disconnected, unknown }
enum ReadingProvenance: String, Codable, Sendable { case systemCache }

enum DeviceBatterySourceState: String, Codable, Sendable, Error {
    case loading, available, bluetoothOff, noDevices, toolUnavailable
    case timedOut, invalidResponse, unavailable, cancelled

    var message: String {
        switch self {
        case .loading: String(localized: "Reading AirPods batteries…")
        case .available: String(localized: "Available")
        case .bluetoothOff: String(localized: "Bluetooth is off")
        case .noDevices: String(localized: "No AirPods connected")
        case .toolUnavailable: String(localized: "Battery reader is unavailable")
        case .timedOut: String(localized: "Device did not respond")
        case .invalidResponse: String(localized: "Battery report is not supported")
        case .unavailable: String(localized: "Battery information is unavailable")
        case .cancelled: String(localized: "Battery update was cancelled")
        }
    }
}

struct BatteryComponentReading: Codable, Sendable, Equatable, Identifiable {
    var component: BatteryComponent
    var percent: Int?
    var chargingState: ChargingState = .unknown
    var readAt: Date
    var sourceUpdatedAt: Date?
    var provenance: ReadingProvenance
    var isStale = false
    var id: BatteryComponent { component }

    mutating func expire(at date: Date) {
        if date.timeIntervalSince(readAt) >= DeviceBatterySnapshot.maximumAge || date < readAt {
            percent = nil
            chargingState = .unknown
            isStale = true
        }
    }
}

struct DeviceBatterySnapshot: Codable, Sendable, Equatable, Identifiable {
    static let maximumAge: TimeInterval = 10 * 60
    var id: String
    var name: String
    var kind: DeviceKind
    var connectionState: ConnectionState
    var components: [BatteryComponentReading]

    var summaryComponents: [BatteryComponentReading] {
        let ears = components.filter { $0.component == .left || $0.component == .right }
        return ears.isEmpty ? components.filter { $0.component == .main } : ears
    }

    // A compact header shows the lower ear, never an average or the case level.
    var compactReading: BatteryComponentReading? {
        summaryComponents.filter { $0.percent != nil }.min { ($0.percent ?? 0) < ($1.percent ?? 0) }
    }

    mutating func markStale(connection: ConnectionState) {
        connectionState = connection
        for index in components.indices {
            components[index].isStale = true
            components[index].chargingState = .unknown
        }
    }

    mutating func expire(at date: Date) {
        for index in components.indices { components[index].expire(at: date) }
    }
}

struct DeviceBatteryRequest: Codable, Sendable {
    var id: UUID = UUID()
    var sources: [DeviceKind] = DeviceKind.allCases
}

struct DeviceBatterySourceResult: Codable, Sendable {
    var source: DeviceKind
    var state: DeviceBatterySourceState
    var devices: [DeviceBatterySnapshot] = []
}

struct DeviceBatteryResult: Codable, Sendable {
    var sources: [DeviceBatterySourceResult]
}
