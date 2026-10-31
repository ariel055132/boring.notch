import SwiftUI

struct DeviceBatteryPopover: View {
    var device: DeviceBatterySnapshot?
    @ObservedObject var manager: DeviceBatteryManager = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let device {
                Text(device.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                if device.connectionState != .connected {
                    Label(device.connectionState == .disconnected ? "Disconnected — last reading" : "Last reading",
                          systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(components(for: device)) { reading in
                    HStack {
                        Text(label(reading.component))
                        Spacer()
                        if reading.isStale { Text("Last read").font(.caption).foregroundStyle(.secondary) }
                        Text(reading.percent.map { "\($0)%" } ?? "—").monospacedDigit()
                        if reading.chargingState == .charging && !reading.isStale {
                            Image(systemName: "bolt.fill").foregroundStyle(.green)
                        }
                    }
                }
                Text("Reported by macOS. The device’s actual update time is unknown; the case may not report while closed.")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = device.components.map(\.readAt).max() {
                    Text("Last checked: \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let state = manager.sourceStates[device.kind], state != .available {
                    Text(state.message).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("AirPods Batteries").font(.headline)
                Text("AirPods appear when this Mac reports their battery. Bluetooth must stay on.")
                Text("Connect your AirPods to this Mac. The header shows the lower AirPod battery. Click it to see both AirPods and the charging case.")
                Text("The charging case may not report while closed. Missing readings appear as —; older readings are marked with a clock.")
                    .font(.caption).foregroundStyle(.secondary)
                if let state = manager.sourceStates[.airPods], state != .available {
                    Text(state.message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("Updates automatically").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { manager.refreshIfNeeded(manual: true) }
                    .disabled(manager.isLoading || !manager.canRefresh)
            }
        }
        .font(.subheadline)
        .padding(16)
        .frame(width: 330)
    }

    private func components(for device: DeviceBatterySnapshot) -> [BatteryComponentReading] {
        let hasEars = device.components.contains { $0.component == .left || $0.component == .right }
        let hasMain = device.components.contains { $0.component == .main }
        let expected: [BatteryComponent] = (hasEars || !hasMain)
            ? [.left, .right, .chargingCase] : [.main]
        return expected.map { component in
            device.components.first { $0.component == component }
                ?? .init(component: component, percent: nil, readAt: .distantPast, provenance: .systemCache)
        }
    }

    private func label(_ component: BatteryComponent) -> String {
        switch component {
        case .main: String(localized: "Battery")
        case .left: String(localized: "Left AirPod")
        case .right: String(localized: "Right AirPod")
        case .chargingCase: String(localized: "Charging case")
        }
    }
}
