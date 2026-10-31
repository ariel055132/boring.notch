import Foundation
import Darwin

private struct Failure: Error { var message: String }

@main
struct DeviceBatteryProbeChecks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        count += 1
    }

    @MainActor static func main() async throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let airpods = """
        {"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},
        "device_connected":[{"Renamed earbuds":{"device_vendorID":"0x004C","device_productID":"0x2024",
        "device_address":"AA-BB-CC-DD-EE-FF","device_batteryLevelLeft":"0%",
        "device_batteryLevelRight":"62%","device_batteryLevelCase":"80%"}}]}]}
        """
        let report = try AirPodsBatteryReader.parseSystemReport(Data(airpods.utf8), at: date)
        try check(report.state == .available && report.devices.count == 1, "connected AirPods are detected by identity")
        let device = report.devices[0]
        try check(device.id == "airpods:AA:BB:CC:DD:EE:FF", "normalize stable address")
        try check(device.components.first?.percent == 0, "zero is a real battery reading")
        try check(device.components.count == 3, "left, right and case stay separate")
        try check(device.components.allSatisfy { $0.sourceUpdatedAt == nil && $0.provenance == .systemCache }, "never fabricate AirPods sample time")
        try check(device.components.allSatisfy { $0.chargingState == .unknown }, "do not invent charging")
        try check(device.summaryComponents.count == 2, "summary shows ears, not case or average")
        try check(device.compactReading?.percent == 0, "compact header preserves a genuinely empty AirPod")
        var compactDevice = device
        compactDevice.components = [
            .init(component: .left, percent: 61, readAt: date, provenance: .systemCache),
            .init(component: .right, percent: 62, readAt: date, provenance: .systemCache),
            .init(component: .chargingCase, percent: 5, readAt: date, provenance: .systemCache)
        ]
        try check(compactDevice.compactReading?.percent == 61, "compact header chooses the lower ear and excludes case")
        compactDevice.components = [.init(component: .main, percent: 80, readAt: date, provenance: .systemCache)]
        try check(compactDevice.compactReading?.percent == 80, "compact header supports a main-only report")
        compactDevice.components[0].percent = nil
        try check(compactDevice.compactReading == nil, "unknown battery remains unknown in compact header")
        for (input, expected) in [("101%", nil), ("-1%", nil), ("NaN", nil), ("55.5%", nil), ("100%", 100), ("0%", 0), (" 42% ", 42)] {
            try check(AirPodsBatteryReader.percentage(input) == expected, "validate percent \(input)")
        }
        try check(AirPodsBatteryReader.percentage(true) == nil, "bool is not battery level")
        try check(AirPodsBatteryReader.percentage(1.5) == nil, "fractional values are invalid")
        try check(AirPodsBatteryReader.percentage(NSNumber(value: Double.infinity)) == nil, "infinite value rejected")
        let thirdParty = airpods.replacingOccurrences(of: "0x004C", with: "0x1234")
        try check(try AirPodsBatteryReader.parseSystemReport(Data(thirdParty.utf8), at: date).devices.isEmpty, "exclude other headphones")
        let off = Data(#"{"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_off"}}]}"#.utf8)
        try check(try AirPodsBatteryReader.parseSystemReport(off, at: date).state == .bluetoothOff, "explicit off state")
        try check(try AirPodsBatteryReader.parseSystemReport(Data(#"{"SPBluetoothDataType":[]}"#.utf8), at: date).state == .unavailable, "empty reporter is not Bluetooth off")
        do { _ = try AirPodsBatteryReader.parseSystemReport(Data("{}".utf8), at: date); throw Failure(message: "invalid schema accepted") }
        catch is DeviceBatterySourceState { count += 1 }
        var old = device
        old.expire(at: date.addingTimeInterval(599))
        try check(old.components[0].percent == 0, "cache before expiry")
        old.expire(at: date.addingTimeInterval(600))
        try check(old.components.allSatisfy { $0.percent == nil && $0.isStale }, "expire exactly at ten minutes")
        try await processes()
        let probe = DeviceBatteryProbe(read: { source in
            .init(source: source, state: .available)
        })
        let result = await probe.fetch(.init())
        try check(result.sources.map(\.source) == [.airPods] && result.sources.map(\.state) == [.available], "default request reads only AirPods")
        let request = DeviceBatteryRequest()
        await probe.cancel(request.id)
        try check(await probe.fetch(request).sources.isEmpty, "cancel before fetch")
        print("Passed \(count) device battery reader/process checks")
    }

    @MainActor static func processes() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        let data = try await DeviceBatteryProcess(executable: python, arguments: ["-c", "print('battery fixture')"]).run()
        try check(String(decoding: data, as: UTF8.self) == "battery fixture\n", "read output through EOF")
        do {
            _ = try await DeviceBatteryProcess(executable: python, arguments: ["-c", "print('x'*5000)"], outputLimit: 1000).run()
            throw Failure(message: "unbounded output")
        } catch let error as DeviceBatterySourceState { try check(error == .invalidResponse, "bound subprocess output") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let args = ["-c", "import os,sys,time,signal; open(sys.argv[1],'w').write(str(os.getpid())); signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)", pidFile.path]
        do {
            _ = try await DeviceBatteryProcess(executable: python, arguments: args, timeout: 0.4).run()
            throw Failure(message: "timeout was ignored")
        } catch let error as DeviceBatterySourceState { try check(error == .timedOut, "hard timeout") }
        if let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8)) {
            try check(kill(pid, 0) == -1 && errno == ESRCH, "timed-out child reaped before return")
        } else { throw Failure(message: "fixture pid missing") }
        let task = Task { try await DeviceBatteryProcess(executable: python, arguments: args).run() }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do { _ = try await task.value; throw Failure(message: "cancellation ignored") }
        catch let error as DeviceBatterySourceState { try check(error == .cancelled, "cancellation reaches process") }
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        try check(kill(pid, 0) == -1 && errno == ESRCH, "cancelled child reaped")
        let missing = DeviceBatteryProcess(executable: directory.appendingPathComponent("missing"))
        do { _ = try await missing.run(); throw Failure(message: "missing tool accepted") }
        catch let error as DeviceBatterySourceState { try check(error == .toolUnavailable, "missing tool reported") }
    }
}
