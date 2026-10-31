import Foundation
import os
@testable import Boring_Notch

private final class StubHelper: NSObject, BoringNotchXPCHelperProtocol, Sendable {
    private struct BatteryState {
        var pending: [String: @Sendable (Data?, String?) -> Void] = [:]
        var cancelled: Set<String> = []
    }
    private let battery = OSAllocatedUnfairLock(initialState: BatteryState())
    var pendingBatteries: Int { battery.withLock { $0.pending.count } }
    func didCancel(_ id: UUID) -> Bool { battery.withLock { $0.cancelled.contains(id.uuidString) } }
    func fetchDeviceBatteries(_ request: Data, with reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard let query = try? JSONDecoder().decode(DeviceBatteryRequest.self, from: request) else {
            reply(nil, DeviceBatterySourceState.invalidResponse.rawValue); return
        }
        if query.sources.isEmpty {
            battery.withLock { $0.pending[query.id.uuidString] = reply }
            return
        }
        let airPods = DeviceBatterySnapshot(id: "fixture", name: "AirPods", kind: .airPods, connectionState: .connected,
            components: [.init(component: .left, percent: 0, readAt: Date(), provenance: .systemCache)])
        reply(try? JSONEncoder().encode(DeviceBatteryResult(sources: [.init(source: .airPods, state: .available, devices: [airPods])])), nil)
    }
    func cancelDeviceBatteryRequest(_ id: String) {
        let reply = battery.withLock { state in
            state.cancelled.insert(id)
            return state.pending.removeValue(forKey: id)
        }
        // Simulate a valid reply racing with cancellation; the client must ignore it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            reply?(try? JSONEncoder().encode(DeviceBatteryResult(sources: [])), nil)
        }
    }
    let authorized: Bool
    init(authorized: Bool) { self.authorized = authorized }
    func fetchClaudeUsage(_ request: Data, with reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard authorized else { reply(nil, ClaudeUsageFailure.permissionRequired.rawValue); return }
        let query = try? JSONDecoder().decode(ClaudeUsageRequest.self, from: request)
        let account = ClaudeUsageAccount(credentialID: "fixture", plan: "pro")
        let snapshot = ClaudeUsageSnapshot(account: account,
            windows: [.init(id: "five_hour", usedPercent: 3, resetsAt: nil)], fetchedAt: Date())
        reply(try? JSONEncoder().encode(ClaudeUsageResult(account: account,
            snapshot: query?.usage == true ? snapshot : nil)), nil)
    }
    func fetchCodexUsage(_ request: Data, with reply: @escaping @Sendable (Data?, String?) -> Void) {
        if authorized {
            let snapshot = CodexUsageSnapshot(accountEmail: nil, plan: "plus", windows: [],
                                              credits: 42, unlimitedCredits: false, fetchedAt: Date())
            let query = try? JSONDecoder().decode(CodexUsageRequest.self, from: request)
            let result = CodexUsageResult(account: .init(email: nil, plan: "plus"), quota: query?.quota == true ? snapshot : nil,
                                          history: query?.history == true ? .init(days: [.init(date: "2026-10-02", tokens: 1234)], fetchedAt: Date()) : nil)
            reply(try? JSONEncoder().encode(result), nil)
        } else {
            reply(nil, CodexUsageFailure.notSignedIn.rawValue)
        }
    }
    func isAccessibilityAuthorized(with reply: @escaping @Sendable (Bool) -> Void) {
        let value = authorized
        DispatchQueue.global().async { reply(value) }
    }
    func requestAccessibilityAuthorization() {}
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping @Sendable (Bool) -> Void) {
        isAccessibilityAuthorized(with: reply)
    }
    func isKeyboardBrightnessAvailable(with reply: @escaping @Sendable (Bool) -> Void) { reply(true) }
    func currentKeyboardBrightness(with reply: @escaping @Sendable (NSNumber?) -> Void) {
        reply(authorized ? NSNumber(value: 0.25) : nil)
    }
    func setKeyboardBrightness(_ value: Float, with reply: @escaping @Sendable (Bool) -> Void) { reply(value == 0.75) }
    func isScreenBrightnessAvailable(with reply: @escaping @Sendable (Bool) -> Void) { reply(true) }
    func currentScreenBrightness(with reply: @escaping @Sendable (NSNumber?) -> Void) { reply(NSNumber(value: 0.5)) }
    func setScreenBrightness(_ value: Float, with reply: @escaping @Sendable (Bool) -> Void) { reply(value == 1) }
}

private final class StubListenerDelegate: NSObject, NSXPCListenerDelegate {
    let helper: StubHelper
    init(authorized: Bool) { helper = StubHelper(authorized: authorized) }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
        connection.exportedObject = helper
        connection.resume()
        return true
    }
}

private final class RejectingListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        false
    }
}

@MainActor
private final class AuthorizationObservations {
    var values: [Bool] = []
}

@MainActor
enum XPCRegressionChecks {
    static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "XPCRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let listener = NSXPCListener.anonymous()
        let delegate = StubListenerDelegate(authorized: true)
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }
        var connections: [NSXPCConnection] = []
        let client = XPCHelperClient(connectionFactory: {
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connections.append(connection)
            return connection
        })
        let observations = AuthorizationObservations()
        let observer = NotificationCenter.default.addObserver(forName: .accessibilityAuthorizationChanged, object: nil, queue: .main) { notification in
            let granted = notification.userInfo?["granted"] as? Bool
            MainActor.assumeIsolated {
                if let granted { observations.values.append(granted) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try check(await client.isAccessibilityAuthorized(), "XPC authorization reply was lost")
        try check(await client.ensureAccessibilityAuthorization(promptIfNeeded: false), "XPC ensure-authorization reply was lost")
        try check(observations.values == [true], "Authorization notifications must be on the main actor and deduplicated")
        try check(await client.isKeyboardBrightnessAvailable(), "Keyboard capability reply was lost")
        try check(await client.currentKeyboardBrightness() == 0.25, "Keyboard brightness NSNumber was not decoded")
        try check(await client.setKeyboardBrightness(0.75), "Keyboard command argument was not delivered")
        try check(await client.isScreenBrightnessAvailable(), "Screen capability reply was lost")
        try check(await client.currentScreenBrightness() == 0.5, "Screen brightness NSNumber was not decoded")
        try check(await client.setScreenBrightness(1), "Screen command argument was not delivered")
        try check(connections.count == 1, "Calls must reuse one live XPC connection")
        let usage = try await client.fetchCodexUsage(.init(quota: true, history: true))
        try check(usage.quota?.credits == 42 && usage.quota?.plan == "plus", "Codex usage must survive real XPC Data serialization")
        try check(usage.history?.days.first?.tokens == 1234, "History flags and daily tokens must survive the XPC boundary")
        let claude = try await client.fetchClaudeUsage(.init(usage: true))
        try check(claude.snapshot?.windows.first?.remainingPercent == 97, "Claude usage must survive real XPC serialization")
        let identity = try await client.fetchClaudeUsage(.init())
        try check(identity.account?.plan == "pro" && identity.snapshot == nil, "Claude identity-only flag must cross XPC")

        let batteries = try await client.fetchDeviceBatteries(.init())
        try check(batteries.sources.first?.devices.first?.components.first?.percent == 0, "Device battery zero survives real XPC serialization")
        let pendingBattery = DeviceBatteryRequest(sources: [])
        let batteryTask = Task { try await client.fetchDeviceBatteries(pendingBattery) }
        let batteryDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while delegate.helper.pendingBatteries == 0 {
            guard ContinuousClock.now < batteryDeadline else { throw NSError(domain: "BatteryXPC", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        batteryTask.cancel()
        do { _ = try await batteryTask.value; try check(false, "Cancelled XPC must finish") }
        catch let error as DeviceBatterySourceState { try check(error == .cancelled, "Cancellation resumes the caller") }
        while !delegate.helper.didCancel(pendingBattery.id) {
            guard ContinuousClock.now < batteryDeadline else { throw NSError(domain: "BatteryXPC", code: 2) }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(delegate.helper.didCancel(pendingBattery.id), "Cancellation reaches helper with exact request ID")
        try await Task.sleep(for: .milliseconds(100))
        try check(await client.currentKeyboardBrightness() == 0.25 && connections.count == 1,
                  "Battery cancellation and late reply preserve the shared XPC connection")

        client.startMonitoringAccessibilityAuthorization(every: 0.01)
        try check(client.isMonitoring, "Authorization monitoring must start")
        client.startMonitoringAccessibilityAuthorization(every: 0.01)
        client.stopMonitoringAccessibilityAuthorization()
        try check(!client.isMonitoring, "Restarted authorization monitoring must stop")

        connections[0].invalidate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            let authorized = await client.isAccessibilityAuthorized()
            if connections.count >= 2 && authorized { break }
            guard ContinuousClock.now < deadline else { throw NSError(domain: "XPCRegression", code: 2) }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(connections.count == 2, "Invalidation must allow a new XPC connection")

        let deniedListener = NSXPCListener.anonymous()
        let deniedDelegate = StubListenerDelegate(authorized: false)
        deniedListener.delegate = deniedDelegate
        deniedListener.resume()
        defer { deniedListener.invalidate(); withExtendedLifetime(deniedDelegate) {} }
        let deniedClient = XPCHelperClient(connectionFactory: { NSXPCConnection(listenerEndpoint: deniedListener.endpoint) })
        try check(!(await deniedClient.ensureAccessibilityAuthorization(promptIfNeeded: false)), "Denied authorization must remain false")
        try check(await deniedClient.currentKeyboardBrightness() == nil, "Unavailable brightness must remain nil")
        do {
            _ = try await deniedClient.fetchCodexUsage(.init(quota: true))
            try check(false, "Codex login failure must not be swallowed")
        } catch let failure as CodexUsageFailure {
            try check(failure == .notSignedIn, "Codex XPC errors must preserve their typed state")
        }
        do {
            _ = try await deniedClient.fetchClaudeUsage(.init(usage: true))
            try check(false, "Claude Keychain failures must not be swallowed")
        } catch let failure as ClaudeUsageFailure {
            try check(failure == .permissionRequired, "Claude XPC errors must preserve their typed state")
        }
        let absentListener = NSXPCListener.anonymous()
        let rejectingDelegate = RejectingListenerDelegate()
        absentListener.delegate = rejectingDelegate
        absentListener.resume()
        defer { absentListener.invalidate(); withExtendedLifetime(rejectingDelegate) {} }
        let absentClient = XPCHelperClient(connectionFactory: { NSXPCConnection(listenerEndpoint: absentListener.endpoint) })
        do {
            _ = try await absentClient.fetchDeviceBatteries(.init())
            try check(false, "Rejected XPC connection must fail")
        } catch let error as DeviceBatterySourceState {
            try check(error == .unavailable, "XPC error callback crosses actors safely")
        }
        return checks
    }
}
