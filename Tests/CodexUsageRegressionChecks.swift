import Foundation
@testable import Boring_Notch

@MainActor
private final class UsageClock {
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
private final class UsageMemoryStore: CodexUsageStoring {
    var state = CodexUsageStoredState()
    func load() -> CodexUsageStoredState { state }
    func save(_ state: CodexUsageStoredState) -> Bool { self.state = state; return true }
}

@MainActor
private final class UsageStub: CodexUsageServiceProviding {
    let clock: UsageClock
    var account = CodexUsageAccount(email: "fixture@example.invalid", plan: "plus")
    var requests: [CodexUsageRequest] = []
    var transportFailure: CodexUsageFailure?
    var quotaIssue: CodexUsageIssue?
    var historyIssue: CodexUsageIssue?
    var paused = false
    var tokens: Int64 = 12345
    private var pending: [CheckedContinuation<Void, Never>] = []
    var quotaCalls: Int { requests.filter(\.quota).count }
    var historyCalls: Int { requests.filter(\.history).count }
    init(_ clock: UsageClock) { self.clock = clock }
    func resume() {
        paused = false
        let continuations = pending
        pending = []
        for continuation in continuations { continuation.resume() }
    }
    func fetchUsage(_ request: CodexUsageRequest) async throws -> CodexUsageResult {
        requests.append(request)
        if paused { await withCheckedContinuation { pending.append($0) } }
        if let failure = transportFailure { throw failure }
        let quota = CodexUsageSnapshot(accountEmail: account.email, plan: account.plan,
            windows: [.init(id: "codex/primary", bucketName: nil, usedPercent: 25, durationMinutes: 300, resetsAt: nil, isPrimary: true)],
            credits: nil, unlimitedCredits: false, fetchedAt: clock.now)
        let history = CodexUsageHistory(days: [.init(date: "2026-10-02", tokens: tokens)], fetchedAt: clock.now)
        return CodexUsageResult(account: account,
            quota: request.quota && quotaIssue == nil ? quota : nil,
            history: request.history && historyIssue == nil ? history : nil,
            quotaIssue: request.quota ? quotaIssue : nil,
            historyIssue: request.history ? historyIssue : nil)
    }
}

@main
@MainActor
private struct CodexUsageRegressionChecks {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "CodexUsageRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    static func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "CodexUsageRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func make(_ clock: UsageClock, store: UsageMemoryStore = .init(), service: UsageStub? = nil) -> (CodexUsageManager, UsageStub) {
        let service = service ?? UsageStub(clock)
        return (CodexUsageManager(service: service, storage: store, now: { clock.now },
            sleepUntil: { try await clock.sleep(until: $0) }, jitter: { 0 }), service)
    }
    static func settle(_ quota: Int, _ history: Int, _ manager: CodexUsageManager, _ service: UsageStub) async throws {
        try await wait("Expected quota \(quota), history \(history) requests to finish") {
            service.quotaCalls == quota && service.historyCalls == history && !manager.isLoading
        }
    }
    static func main() async throws {
        try await schedulingAndRelaunch()
        try await partialFailuresAndIdentity()
        try await persistentBackoff()
        try await pendingAndCancellation()
        try await pendingExpiryAndAnonymousAccount()
        try dailyTotalsAndDates()
        try diskCache()
        print("Codex usage manager/history checks passed: \(checks)")
    }

    static func schedulingAndRelaunch() async throws {
        let clock = UsageClock()
        let store = UsageMemoryStore()
        let (manager, service) = make(clock, store: store)
        defer { manager.stopBackgroundUpdates() }
        manager.startBackgroundUpdates()
        manager.startBackgroundUpdates()
        manager.loadIfNeeded()
        try await settle(1, 1, manager, service)
        try expect(service.requests.first == .init(), "Identity must be checked before disk data can be displayed")
        try expect(manager.snapshot?.windows.first?.remainingPercent == 75 && manager.history != nil, "First launch must fetch both views")
        try expect(!manager.canRefresh && !manager.canRefreshHistory, "Manual refresh must share both gates")
        clock.advance(179)
        for _ in 0..<10 { manager.refresh() }
        try expect(service.quotaCalls == 1 && service.historyCalls == 1, "Repeated clicks must not send requests")
        clock.advance(1)
        try await settle(2, 1, manager, service)
        try expect(manager.history?.fetchedAt != manager.snapshot?.fetchedAt, "Quota updates must not change the history timestamp")
        clock.advance(3420)
        manager.loadIfNeeded()
        try await settle(3, 2, manager, service)
        try expect(service.requests.count == 4, "Missed intervals must coalesce, with one hourly history request")
        manager.stopBackgroundUpdates()
        let (reopened, second) = make(clock, store: store)
        defer { reopened.stopBackgroundUpdates() }
        try expect(reopened.history == nil, "Unverified disk history must stay hidden")
        reopened.startBackgroundUpdates()
        try await wait("Reopened app must verify identity") { reopened.account != nil && !reopened.isLoading }
        try expect(second.requests == [.init()], "Relaunch within cooldown must make no statistics requests")
        try expect(reopened.history?.days.first?.tokens == 12345 && reopened.snapshot != nil, "Verified account must restore its cached data")
        clock.advance(3599)
        reopened.refresh()
        try await settle(1, 0, reopened, second)
        try expect(second.historyCalls == 0, "Relaunch must preserve the one-hour history gate")
        clock.advance(1)
        try await settle(1, 1, reopened, second)
        try expect(second.requests.last == .init(history: true), "An hourly update can query history without extra quota requests")
    }

    static func partialFailuresAndIdentity() async throws {
        let clock = UsageClock()
        let store = UsageMemoryStore()
        let (manager, service) = make(clock, store: store)
        defer { manager.stopBackgroundUpdates() }
        manager.startBackgroundUpdates()
        try await settle(1, 1, manager, service)
        let original = manager.history!.fetchedAt
        service.transportFailure = .connection
        clock.advance(1800)
        manager.loadIfNeeded()
        try await settle(2, 1, manager, service)
        try expect(manager.snapshot == nil && manager.history?.fetchedAt == original, "History must survive the quota's thirty-minute expiry")
        service.transportFailure = nil
        service.historyIssue = .init(failure: .connection)
        clock.advance(1800)
        try await settle(3, 2, manager, service)
        try expect(manager.snapshot != nil && manager.history?.fetchedAt == original,
                   "Failed history must preserve the original successful timestamp and fresh quota")
        try expect(manager.historyFailure == .connection && manager.failure == nil, "The two views need independent error states")
        service.historyIssue = nil
        service.account = .init(email: "second@example.invalid", plan: "plus")
        service.tokens = 987
        clock.advance(180)
        try await settle(4, 3, manager, service)
        try expect(manager.history?.days.first?.tokens == 987 && manager.account?.email == "second@example.invalid",
                   "Changing accounts must not display or merge the previous account's history")
        service.transportFailure = .notSignedIn
        clock.advance(180)
        try await settle(5, 3, manager, service)
        try expect(manager.snapshot == nil && manager.history == nil && manager.account == nil,
                   "Sign-out must immediately hide all account data")
        try expect(store.state.accounts["second@example.invalid|plus"]?.history == nil,
                   "Sign-out must discard cached account data")
        try expect(store.state.accounts["second@example.invalid|plus"]?.nextHistoryAt != nil,
                   "Sign-out must not discard the history cooldown")
    }

    static func persistentBackoff() async throws {
        let clock = UsageClock()
        let store = UsageMemoryStore()
        let (manager, service) = make(clock, store: store)
        manager.startBackgroundUpdates()
        try await settle(1, 1, manager, service)
        service.historyIssue = .init(failure: .rateLimited, retryAt: clock.now.addingTimeInterval(10800))
        clock.advance(3600)
        try await settle(2, 2, manager, service)
        let retry = clock.now.addingTimeInterval(7200)
        try expect(manager.retryAt == retry, "A server hint longer than local backoff must be honored")
        try expect(!manager.canRefresh && !manager.canRefreshHistory, "History throttling must also pause quota checks")
        manager.stopBackgroundUpdates()
        let (reopened, second) = make(clock, store: store)
        defer { reopened.stopBackgroundUpdates() }
        reopened.startBackgroundUpdates()
        reopened.refresh()
        try expect(second.requests.isEmpty && reopened.retryAt == retry, "Restart must not bypass a shared server cooldown")
        clock.advance(7199)
        reopened.loadIfNeeded()
        try expect(second.requests.isEmpty, "No request may run before the full server delay")
        clock.advance(1)
        try await settle(1, 1, reopened, second)
        try expect(reopened.retryAt == nil && reopened.historyFailure == nil, "Successful recovery must clear the cooldown")
        second.quotaIssue = .init(failure: .rateLimited)
        clock.advance(180)
        try await settle(2, 1, reopened, second)
        try expect(reopened.retryAt == clock.now.addingTimeInterval(360), "First unhinted throttle waits six minutes")
        clock.advance(360)
        try await settle(3, 1, reopened, second)
        try expect(reopened.retryAt == clock.now.addingTimeInterval(720), "Repeated throttling must increase backoff")
    }

    static func pendingAndCancellation() async throws {
        let clock = UsageClock()
        let store = UsageMemoryStore()
        let (manager, service) = make(clock, store: store)
        manager.startBackgroundUpdates()
        try await settle(1, 1, manager, service)
        service.paused = true
        clock.advance(3600)
        try await wait("Hourly request must be pending") { service.historyCalls == 2 }
        manager.refresh()
        manager.loadIfNeeded()
        try expect(service.quotaCalls == 2 && service.historyCalls == 2, "In-flight requests must coalesce")
        try expect(store.state.accounts[service.account.cacheKey!]?.nextHistoryAt == clock.now.addingTimeInterval(3600),
                   "Cooldown must be saved before a request completes")
        manager.stopBackgroundUpdates()
        service.resume()
        try await Task.sleep(for: .milliseconds(20))
        try expect(manager.history?.fetchedAt != clock.now && !manager.isLoading, "Canceled late results must not replace history")
        let (reopened, second) = make(clock, store: store)
        defer { reopened.stopBackgroundUpdates() }
        reopened.startBackgroundUpdates()
        try await wait("Reopen should restore old history") { reopened.history != nil && !reopened.isLoading }
        try expect(second.historyCalls == 0 && second.quotaCalls == 0, "Quitting during a request must not bypass either cooldown")
    }

    static func dailyTotalsAndDates() throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-03T15:00:00Z")!
        let history = CodexUsageHistory(days: [
            .init(date: "2026-09-26", tokens: 999), .init(date: "2026-09-27", tokens: 0),
            .init(date: "2026-09-29", tokens: 10), .init(date: "2026-10-02", tokens: 20),
            .init(date: "2026-10-04", tokens: 999)
        ], fetchedAt: date)
        let days = history.recentDays(at: date, timeZone: TimeZone(identifier: "Asia/Taipei")!)
        try expect(days.map(\.id) == ["2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03"],
                   "The chart must show seven calendar dates including today")
        try expect(days[0].tokens == 0 && days[1].tokens == nil, "Reported zero and a missing day are different")
        try expect(CodexUsageHistory.reportedTotal(days) == 30, "Only reported days inside the seven-day window count")
        let empty = CodexUsageHistory(days: [], fetchedAt: date).recentDays(at: date)
        try expect(CodexUsageHistory.reportedTotal(empty) == nil, "An empty report must not claim zero total usage")
        let overflow = [CodexUsageDay(id: "a", date: date, tokens: .max), .init(id: "b", date: date, tokens: 1)]
        try expect(CodexUsageHistory.reportedTotal(overflow) == nil, "Totals must not overflow or trap")
        let dstDate = ISO8601DateFormatter().date(from: "2026-03-10T12:00:00Z")!
        let dst = history.recentDays(at: dstDate, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        try expect(Set(dst.map(\.id)).count == 7 && dst.first?.id == "2026-03-04", "DST must not skip or duplicate calendar days")
    }

    static func pendingExpiryAndAnonymousAccount() async throws {
        let clock = UsageClock()
        let (manager, service) = make(clock)
        manager.startBackgroundUpdates()
        try await settle(1, 1, manager, service)
        service.paused = true
        clock.advance(180)
        try await wait("Quota request must be pending") { service.quotaCalls == 2 }
        clock.advance(1620)
        try await wait("Quota must expire during a pending query") { manager.snapshot == nil }
        try expect(manager.history != nil && manager.isLoading, "Pending quota expiry must preserve history")
        try expect(service.quotaCalls == 2, "Expiry must not start overlapping requests")
        manager.stopBackgroundUpdates()
        service.resume()
        try await Task.sleep(for: .milliseconds(20))
        try expect(manager.snapshot == nil, "Canceled pending quota must stay expired")

        let store = UsageMemoryStore()
        let anonymous = UsageStub(clock)
        anonymous.account = .init(email: nil, plan: "plus")
        let (first, _) = make(clock, store: store, service: anonymous)
        first.startBackgroundUpdates()
        try await settle(1, 1, first, anonymous)
        first.stopBackgroundUpdates()
        try expect(store.state.accounts.isEmpty, "Accounts without email must not persist usage data")
        let nextService = UsageStub(clock)
        nextService.account = anonymous.account
        let (next, _) = make(clock, store: store, service: nextService)
        defer { next.stopBackgroundUpdates() }
        next.startBackgroundUpdates()
        try await wait("Anonymous identity check must complete") { next.account != nil && !next.isLoading }
        try expect(nextService.quotaCalls == 0 && nextService.historyCalls == 0, "Missing account identifiers must not bypass persisted cooldowns")
        try expect(next.history == nil, "Unidentifiable history must not be restored across launches")
    }

    static func diskCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-history-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CodexUsageFileStore(url: directory.appendingPathComponent("Usage.json"))
        var state = CodexUsageStoredState()
        state.blockedUntil = Date(timeIntervalSince1970: 1_800_007_200)
        state.accounts["fixture@example.invalid|plus"] = .init(history: .init(days: [.init(date: "2026-10-02", tokens: 42)], fetchedAt: Date()),
                                                               nextHistoryAt: state.blockedUntil)
        try expect(store.save(state), "Cache must write atomically to its application support directory")
        let restored = store.load()
        try expect(restored.blockedUntil == state.blockedUntil && restored.accounts.values.first?.history?.days.first?.tokens == 42,
                   "Disk cache must round-trip history and cooldowns")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        try expect(attributes[.posixPermissions] as? Int == 0o600, "Usage cache must be private to this user")
        try Data("broken-json".utf8).write(to: store.url)
        try expect(store.load().accounts.isEmpty, "A corrupt cache must fail safely")
    }
}
