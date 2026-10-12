import Foundation
@testable import Boring_Notch

@MainActor
private final class ClaudeClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var sleepers: [UUID: (Date, CheckedContinuation<Void, Error>)] = [:]
    func advance(_ seconds: TimeInterval) {
        now.addTimeInterval(seconds)
        for (id, entry) in sleepers.filter({ $0.value.0 <= now }) {
            sleepers.removeValue(forKey: id)
            entry.1.resume()
        }
    }
    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if deadline <= now { return }
            try await withCheckedThrowingContinuation { sleepers[id] = (deadline, $0) }
        } onCancel: {
            Task { @MainActor in self.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }
}

@MainActor
private final class ClaudeMemoryStore: ClaudeUsageStoring {
    var state = ClaudeUsageStoredState()
    var writable = true
    func load() -> ClaudeUsageStoredState { state }
    func save(_ state: ClaudeUsageStoredState) -> Bool { self.state = state; return writable }
}

@MainActor
private final class ClaudeStub: ClaudeUsageServiceProviding {
    let clock: ClaudeClock
    var account = ClaudeUsageAccount(credentialID: "account-a", plan: "pro")
    var requests: [ClaudeUsageRequest] = []
    var issue: ClaudeUsageIssue?
    var credentialFailure: ClaudeUsageFailure?
    var paused = false
    var mismatch = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    var calls: Int { requests.filter(\.usage).count }
    init(_ clock: ClaudeClock) { self.clock = clock }
    func resume() {
        paused = false
        let continuations = pending
        pending = []
        for continuation in continuations { continuation.resume() }
    }
    func fetchUsage(_ request: ClaudeUsageRequest) async throws -> ClaudeUsageResult {
        requests.append(request)
        if paused { await withCheckedContinuation { pending.append($0) } }
        if let credentialFailure { return .init(issue: .init(failure: credentialFailure)) }
        let value = ClaudeUsageSnapshot(account: mismatch ? .init(credentialID: "wrong", plan: "max") : account,
            windows: [.init(id: "five_hour", usedPercent: 3, resetsAt: nil)], fetchedAt: clock.now)
        return .init(account: account, snapshot: request.usage && issue == nil ? value : nil,
                     issue: request.usage ? issue : nil)
    }
}

@main
@MainActor
private struct ClaudeUsageRegressionChecks {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "ClaudeManagerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    static func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "ClaudeManagerChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func make(_ clock: ClaudeClock, store: ClaudeMemoryStore = .init(), service: ClaudeStub? = nil) -> (ClaudeUsageManager, ClaudeStub) {
        let service = service ?? ClaudeStub(clock)
        return (ClaudeUsageManager(service: service, storage: store, now: { clock.now },
            sleepUntil: { try await clock.sleep(until: $0) }, jitter: { 0 }), service)
    }
    static func settle(_ calls: Int, _ manager: ClaudeUsageManager, _ service: ClaudeStub) async throws {
        try await wait("Expected \(calls) usage requests to finish") { service.calls == calls && !manager.isLoading }
    }
    static func main() async throws {
        try await schedulingAndRelaunch()
        try await identityAndReconnect()
        try await backoffAndExpiry()
        try await cancellationAndPendingExpiry()
        try diskCache()
        print("Claude usage manager/cache checks passed: \(checks)")
    }

    static func schedulingAndRelaunch() async throws {
        let clock = ClaudeClock(), store = ClaudeMemoryStore()
        let (manager, service) = make(clock, store: store)
        manager.startBackgroundUpdates()
        manager.startBackgroundUpdates()
        manager.loadIfNeeded()
        try await settle(1, manager, service)
        try expect(service.requests.first == .init(), "Local identity must be verified first")
        try expect(manager.snapshot?.windows.first?.remainingPercent == 97, "First verified fetch must publish remaining usage")
        try expect(!manager.canRefresh && store.state.nextUsageAt == clock.now.addingTimeInterval(300), "Attempt deadline must be persisted")
        clock.advance(299)
        for _ in 0..<10 { manager.refresh(); manager.loadIfNeeded() }
        try expect(service.calls == 1, "Clicks, wake and view appearances share the cooldown")
        manager.stopBackgroundUpdates()
        let (relaunched, second) = make(clock, store: store)
        defer { relaunched.stopBackgroundUpdates() }
        try expect(relaunched.snapshot == nil, "Unverified disk cache must stay hidden")
        relaunched.startBackgroundUpdates()
        try await wait("Cache identity verification") { relaunched.snapshot != nil && !relaunched.isLoading }
        try expect(second.calls == 0, "Relaunch may verify identity but must not bypass HTTP cooldown")
        clock.advance(1)
        try await settle(1, relaunched, second)
        try expect(relaunched.snapshot?.fetchedAt == clock.now, "Timer must fetch at the deadline")
        clock.advance(1200)
        relaunched.loadIfNeeded()
        try await settle(2, relaunched, second)
        try expect(second.calls == 2, "Wake after multiple intervals must make only one request")
        store.writable = false
        clock.advance(300)
        relaunched.loadIfNeeded()
        try await settle(3, relaunched, second)
        try expect(relaunched.cacheUnavailable && relaunched.snapshot != nil, "Disk failure must be visible without discarding current usage")
    }

    static func identityAndReconnect() async throws {
        let clock = ClaudeClock(), store = ClaudeMemoryStore()
        let (manager, service) = make(clock, store: store)
        defer { manager.stopBackgroundUpdates() }
        service.credentialFailure = .permissionRequired
        manager.loadIfNeeded()
        try await wait("Permission failure") { manager.failure == .permissionRequired && !manager.isLoading }
        try expect(service.calls == 0 && service.requests.allSatisfy { !$0.allowKeychainPrompt }, "Background checks must not prompt or send unauthenticated requests")
        service.credentialFailure = nil
        manager.connect()
        try await settle(1, manager, service)
        try expect(service.requests.contains { $0.allowKeychainPrompt && !$0.usage }, "Connect must explicitly request a local Keychain prompt")
        service.account = .init(credentialID: "account-b", plan: "max")
        manager.connect()
        try await wait("Changed account verification") { manager.account == service.account && !manager.isLoading }
        try expect(manager.snapshot == nil && store.state.snapshot == nil, "Changed identity must discard another account's cache")
        try expect(service.calls == 1, "Changing accounts must not bypass the shared usage deadline")
        clock.advance(300)
        manager.refresh()
        try await settle(2, manager, service)
        try expect(manager.snapshot?.account.plan == "max", "New account must get only its own usage")
        service.issue = .init(failure: .expiredLogin)
        clock.advance(300)
        manager.refresh()
        try await settle(3, manager, service)
        try expect(manager.snapshot == nil && manager.account == nil && manager.failure == .expiredLogin, "Expired login must clear identity and quota")
        service.issue = nil
        service.account = .init(credentialID: "refreshed-credential", plan: "max")
        manager.connect()
        try await wait("Refreshed credential") { manager.account == service.account && !manager.isLoading }
        try expect(service.calls == 3, "Reconnect must not reset the persisted remote gate")
        clock.advance(300)
        service.mismatch = true
        manager.refresh()
        try await settle(4, manager, service)
        try expect(manager.snapshot == nil && manager.failure == .invalidResponse, "Mismatched account in a reply must be rejected")
    }

    static func backoffAndExpiry() async throws {
        let clock = ClaudeClock(), store = ClaudeMemoryStore()
        let (manager, service) = make(clock, store: store)
        manager.startBackgroundUpdates()
        try await settle(1, manager, service)
        service.issue = .init(failure: .connection)
        clock.advance(300)
        try await settle(2, manager, service)
        try expect(manager.snapshot != nil && manager.failure == .connection, "Temporary errors may show explicitly stale usage")
        service.issue = .init(failure: .rateLimited, retryAt: clock.now.addingTimeInterval(7200))
        clock.advance(300)
        try await settle(3, manager, service)
        let blocked = manager.retryAt
        try expect(blocked == service.issue?.retryAt && !manager.canRefresh, "Server Retry-After may exceed local backoff")
        manager.connect()
        try await wait("Reconnect during cooldown") { !manager.isLoading }
        try expect(service.calls == 3 && manager.retryAt == blocked, "Connect must preserve server cooldown")
        clock.advance(1200)
        try await wait("Cache expiry during cooldown") { manager.snapshot == nil }
        try expect(service.calls == 3 && store.state.snapshot == nil, "Quota must expire at 30 minutes even when requests are blocked")
        manager.stopBackgroundUpdates()
        let (next, nextService) = make(clock, store: store)
        defer { next.stopBackgroundUpdates() }
        nextService.issue = .init(failure: .rateLimited)
        next.startBackgroundUpdates()
        try await wait("Relaunch during cooldown") { next.account != nil && !next.isLoading }
        try expect(nextService.calls == 0 && next.retryAt == blocked, "Relaunch must preserve rate limiting")
        clock.advance(blocked!.timeIntervalSince(clock.now))
        try await settle(1, next, nextService)
        try expect(store.state.rateLimitDelay == 1200, "Repeated rate limiting must double delay across relaunch")
        clock.advance(1200)
        try await settle(2, next, nextService)
        try expect(store.state.rateLimitDelay == 1800, "Local exponential backoff must cap at 30 minutes")
        nextService.issue = nil
        clock.advance(1800)
        try await settle(3, next, nextService)
        try expect(next.retryAt == nil && next.failure == nil && store.state.rateLimitDelay == 300, "Success must reset backoff")
    }

    static func cancellationAndPendingExpiry() async throws {
        let clock = ClaudeClock(), store = ClaudeMemoryStore()
        let (manager, service) = make(clock, store: store)
        manager.startBackgroundUpdates()
        try await settle(1, manager, service)
        service.paused = true
        clock.advance(300)
        try await wait("Pending request") { service.calls == 2 && manager.isLoading }
        try expect(store.state.nextUsageAt == clock.now.addingTimeInterval(300), "In-flight attempt must already be saved")
        clock.advance(1500)
        try await wait("Expire during pending reply") { manager.snapshot == nil }
        try expect(service.calls == 2 && manager.isLoading, "An in-flight request must not prevent cache expiry or spawn duplicates")
        manager.stopBackgroundUpdates()
        service.resume()
        try await Task.sleep(for: .milliseconds(40))
        try expect(manager.snapshot == nil && !manager.isLoading, "Cancelled late replies must not publish quota")
        manager.startBackgroundUpdates()
        try await settle(3, manager, service)
        manager.stopBackgroundUpdates()
        try expect(manager.snapshot != nil, "Restarting after cancellation must recover")
    }

    static func diskCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ClaudeUsage.json")
        let store = ClaudeUsageFileStore(url: url)
        let state = ClaudeUsageStoredState(nextUsageAt: Date(timeIntervalSince1970: 12345),
            blockedUntil: Date(timeIntervalSince1970: 23456), rateLimitDelay: 600)
        try expect(store.save(state), "Cache file must save")
        try expect(store.load().blockedUntil == state.blockedUntil, "Cooldown must round-trip to disk")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Usage cache must be private to this user")
        try Data("broken".utf8).write(to: url)
        try expect(store.load().snapshot == nil, "Corrupt disk data must not crash")
        var invalid = state
        invalid.version = 99
        try JSONEncoder().encode(invalid).write(to: url)
        try expect(store.load().version == 1, "Unknown cache versions must be ignored")
    }
}
