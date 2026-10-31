import SwiftUI

struct DeviceBatteryIndicator: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject var manager: DeviceBatteryManager = .shared
    @State private var selectedID: String?
    @State private var showPopover = false
    @State private var dismissTask: Task<Void, Never>?
    @State private var isHoveringButton = false
    @State private var isHoveringPopover = false

    private var device: DeviceBatterySnapshot? {
        manager.devices.first { $0.connectionState == .connected } ?? manager.devices.first
    }

    private var reading: BatteryComponentReading? { device?.compactReading }

    private var isStale: Bool {
        device.map { $0.connectionState != .connected } == true || reading?.isStale == true
    }

    private var helpText: String {
        guard let device else {
            return manager.sourceStates[.airPods]?.message ?? String(localized: "No AirPods connected")
        }
        return device.name + " — " + String(localized: "Shows the lower AirPod battery. Click for both AirPods and the case.")
    }

    var body: some View {
        Button {
            selectedID = device?.id
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "airpodspro")
                    .font(.system(size: 14))
                    .foregroundStyle(!isStale && (reading?.percent ?? 100) <= 20 ? .red : .white)
                    .overlay(alignment: .bottomTrailing) {
                        if isStale {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.gray)
                                .background(.black, in: Circle())
                                .offset(x: 3, y: 2)
                        }
                    }
                Text(reading?.percent.map { "\($0)%" } ?? "—")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .opacity(isStale || reading == nil ? 0.5 : 1)
            .padding(.horizontal, 4)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
        .fixedSize()
        .help(helpText)
        .accessibilityLabel(Text("AirPods battery"))
        .accessibilityValue(Text(reading?.percent.map { "\($0)%" } ?? "—"))
        .onHover { hovering in
            isHoveringButton = hovering
            if hovering { dismissTask?.cancel() }
            else { scheduleDismissIfNeeded() }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                if manager.devices.count > 1 {
                    Picker("AirPods", selection: $selectedID) {
                        ForEach(manager.devices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .padding([.top, .horizontal], 16)
                }
                DeviceBatteryPopover(device: manager.devices.first { $0.id == selectedID } ?? device, manager: manager)
            }
            .onHover { hovering in
                isHoveringPopover = hovering
                if hovering { dismissTask?.cancel() }
                else { scheduleDismissIfNeeded() }
            }
        }
        .onChange(of: showPopover) { vm.isDeviceBatteryPopoverActive = showPopover }
        .onDisappear {
            dismissTask?.cancel()
            showPopover = false
            vm.isDeviceBatteryPopoverActive = false
        }
        .onAppear { manager.refreshIfNeeded() }
    }

    private func scheduleDismissIfNeeded() {
        guard !isHoveringButton, !isHoveringPopover else { return }
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            showPopover = false
        }
    }
}
