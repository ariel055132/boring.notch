import Foundation
@testable import Boring_Notch

private struct Failure: Error { var message: String }

@MainActor
private final class Fixture {
    var date = Date(timeIntervalSince1970: 10_000)
    var requests: [DeviceBatteryRequest] = []
    var cancelled: [UUID] = []
    var result = DeviceBatteryResult(sources: [])
    var hold = false
    var pending: CheckedContinuation<DeviceBatteryResult, Error>?

    func makeManager() -> DeviceBatteryManager {
        DeviceBatteryManager(fetch: { request in
            self.requests.append(request)
            if self.hold { return try await withCheckedThrowingContinuation { self.pending = $0 } }
            return self.result
        }, cancel: { self.cancelled.append($0) }, now: { self.date }, sleepUntil: { _ in
            try await Task.sleep(for: .seconds(3600))
        })
    }

    func report(left: Int? = 66, right: Int? = 62, box: Int? = 80) -> DeviceBatteryResult {
        let readings: [(BatteryComponent, Int?)] = [(.left, left), (.right, right), (.chargingCase, box)]
        return .init(sources: [.init(source: .airPods, state: .available, devices: [
            .init(id: "airpods:fixture", name: "Fixture", kind: .airPods, connectionState: .connected,
                  components: readings.compactMap { component, value in
                      value.map { .init(component: component, percent: $0, readAt: date, provenance: .systemCache) }
                  })])])
    }
}

@main
struct DeviceBatteryRegressionChecks {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        checks += 1
    }
    @MainActor static func settle(_ manager: DeviceBatteryManager) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while manager.isLoading {
            if ContinuousClock.now > deadline { throw Failure(message: "manager did not settle") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor static func main() async throws {
        let fixture = Fixture()
        fixture.result = fixture.report()
        let manager = fixture.makeManager()
        manager.startBackgroundUpdates()
        manager.startBackgroundUpdates()
        manager.refreshIfNeeded()
        try await settle(manager)
        try check(fixture.requests.count == 1, "one shared startup request across views")
        try check(manager.devices.count == 1, "publish initial device")
        try check(manager.sourceStates == [.airPods: .available], "publish only AirPods source state")
        manager.refreshIfNeeded(manual: true)
        try check(fixture.requests.count == 1, "manual retry cooldown")
        fixture.date += 15
        manager.refreshIfNeeded(manual: true)
        try await settle(manager)
        try check(fixture.requests.count == 2, "manual refresh after fifteen seconds")
        fixture.date += 60
        fixture.result = fixture.report(left: 0, box: nil)
        manager.refreshIfNeeded()
        try await settle(manager)
        try check(fixture.requests.last?.sources == [.airPods], "scheduled refresh requests only AirPods")
        let box = manager.devices[0].components.first { $0.component == .chargingCase }!
        try check(box.isStale && box.percent == 80, "missing case keeps identifiable stale reading")
        try check(box.readAt == Date(timeIntervalSince1970: 10_000), "missing case does not inherit ear timestamp")
        try check(manager.devices[0].components.first { $0.component == .left }?.percent == 0, "zero survives manager merge")
        fixture.date += 525
        fixture.result = fixture.report(box: nil)
        manager.refreshIfNeeded()
        try await settle(manager)
        try check(manager.devices[0].components.first { $0.component == .chargingCase }?.percent == nil, "case expires independently")
        try check(manager.devices[0].components.first { $0.component == .left }?.percent == 66, "healthy ear survives case expiry")
        fixture.date += 60
        fixture.result = .init(sources: [.init(source: .airPods, state: .bluetoothOff)])
        manager.refreshIfNeeded()
        try await settle(manager)
        try check(manager.devices[0].connectionState == .disconnected, "Bluetooth off disconnects cached device")
        try check(manager.devices[0].components.allSatisfy(\.isStale), "failed source marks old values immediately")
        let requestsBeforeBackoff = fixture.requests.count
        fixture.date += 60
        manager.refreshIfNeeded()
        try check(fixture.requests.count == requestsBeforeBackoff, "first failure waits longer than the healthy interval")
        fixture.date += 60
        manager.refreshIfNeeded()
        try await settle(manager)
        try check(fixture.requests.count == requestsBeforeBackoff + 1, "retry after the first failure backoff")
        fixture.date += 120
        manager.refreshIfNeeded()
        try check(fixture.requests.count == requestsBeforeBackoff + 1, "repeated failures extend backoff")
        fixture.date += 600
        manager.refreshIfNeeded()
        try await settle(manager)
        try check(manager.devices[0].components.allSatisfy { $0.percent == nil }, "expired values clear")
        manager.stopBackgroundUpdates(clear: true)
        try check(!manager.isRunning && manager.devices.isEmpty && manager.sourceStates.isEmpty, "disable clears data and stops")
        manager.refreshIfNeeded(manual: true)
        try check(!manager.isLoading, "disabled manager cannot restart from UI")

        let held = Fixture()
        held.hold = true
        let heldManager = held.makeManager()
        heldManager.startBackgroundUpdates()
        while held.pending == nil { await Task.yield() }
        heldManager.stopBackgroundUpdates(clear: true)
        try check(held.cancelled == held.requests.map(\.id), "stop cancels exact XPC request")
        held.pending?.resume(returning: held.report()); held.pending = nil
        for _ in 0..<10 { await Task.yield() }
        try check(heldManager.devices.isEmpty && !heldManager.isLoading, "late response cannot repopulate disabled UI")
        held.hold = false; held.result = held.report()
        heldManager.startBackgroundUpdates()
        try await settle(heldManager)
        try check(heldManager.devices.count == 1, "resume after cancellation")
        heldManager.stopBackgroundUpdates()
        try check(heldManager.devices[0].components.allSatisfy(\.isStale), "sleep marks cached data old")
        let old = heldManager.devices[0].components[0].readAt
        try check(old == held.date, "sleep does not refresh timestamps")
        print("Passed \(checks) device battery manager checks")
    }
}
