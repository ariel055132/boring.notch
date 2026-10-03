import Combine
import Foundation

struct CodexUsageCacheRecord: Codable {
    var quota: CodexUsageSnapshot?
    var history: CodexUsageHistory?
    var nextQuotaAt: Date?
    var nextHistoryAt: Date?
}

struct CodexUsageStoredState: Codable {
    var version = 1
    var accounts: [String: CodexUsageCacheRecord] = [:]
    var blockedUntil: Date?
    var rateLimitDelay: TimeInterval = 180
    var rateLimitSource: String?
    var nextIdentityAt: Date?
    var anonymousNextQuotaAt: Date?
    var anonymousNextHistoryAt: Date?
}

@MainActor
protocol CodexUsageStoring {
    func load() -> CodexUsageStoredState
    func save(_ state: CodexUsageStoredState) -> Bool
}

struct CodexUsageFileStore: CodexUsageStoring {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory
            .appendingPathComponent("boringNotch/CodexUsage.json")
    }

    func load() -> CodexUsageStoredState {
        guard let data = try? Data(contentsOf: url), data.count <= 2_000_000,
              let state = try? JSONDecoder().decode(CodexUsageStoredState.self, from: data),
              state.version == 1, state.accounts.count <= 5,
              state.rateLimitDelay.isFinite, state.rateLimitDelay >= 180 else { return .init() }
        return state
    }

    func save(_ state: CodexUsageStoredState) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}

@MainActor
final class CodexUsageManager: ObservableObject {
    static let shared = CodexUsageManager()
    static let refreshInterval: TimeInterval = 3 * 60
    static let historyRefreshInterval: TimeInterval = 60 * 60
    static let maximumCacheAge: TimeInterval = 30 * 60

    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var history: CodexUsageHistory?
    @Published private(set) var account: CodexUsageAccount?
    @Published private(set) var failure: CodexUsageFailure?
    @Published private(set) var historyFailure: CodexUsageFailure?
    @Published private(set) var isLoading = false
    @Published private(set) var canRefresh = false
    @Published private(set) var canRefreshHistory = false
    @Published private(set) var cacheUnavailable = false
    @Published private(set) var retryAt: Date?

    private let service: any CodexUsageServiceProviding
    private let storage: any CodexUsageStoring
    private let now: @MainActor () -> Date
    private let sleepUntil: @MainActor (Date) async throws -> Void
    private let jitter: @MainActor () -> TimeInterval
    private var stored: CodexUsageStoredState
    private var record = CodexUsageCacheRecord()
    private var identityVerified = false
    private var refreshTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var isRunning = false
    private var generation: UInt = 0

    init(service: any CodexUsageServiceProviding = CodexUsageService(),
         storage: any CodexUsageStoring = CodexUsageFileStore(),
         now: @escaping @MainActor () -> Date = { Date() },
         sleepUntil: @escaping @MainActor (Date) async throws -> Void = { deadline in
             try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
         }, jitter: @escaping @MainActor () -> TimeInterval = { Double.random(in: 0...30) }) {
        self.service = service
        self.storage = storage
        self.now = now
        self.sleepUntil = sleepUntil
        self.jitter = jitter
        self.stored = storage.load()
        // Disk data stays hidden until account/read verifies the current account.
        if let until = stored.blockedUntil, until > now() {
            failure = .rateLimited
            historyFailure = .rateLimited
            retryAt = until
        }
    }

    isolated deinit {
        refreshTask?.cancel()
        timer?.cancel()
    }

    func startBackgroundUpdates() {
        guard !isRunning else { return }
        isRunning = true
        loadIfNeeded()
    }

    func stopBackgroundUpdates() {
        isRunning = false
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        timer?.cancel()
        timer = nil
        isLoading = false
        updateAvailabilityAndTimer()
    }

    func refresh() { loadIfNeeded() }

    // All windows, manual refreshes, wake and relaunch share persisted gates.
    func loadIfNeeded() {
        expireQuota()
        defer { updateAvailabilityAndTimer() }
        let date = now()
        guard !isLoading, stored.blockedUntil.map({ date >= $0 }) ?? true else { return }
        let request: CodexUsageRequest
        if !identityVerified {
            guard stored.nextIdentityAt.map({ date >= $0 }) ?? true else { return }
            request = .init() // Local identity check; no statistics request.
            stored.nextIdentityAt = date.addingTimeInterval(Self.refreshInterval)
        } else {
            request = .init(quota: record.nextQuotaAt.map({ date >= $0 }) ?? true,
                            history: record.nextHistoryAt.map({ date >= $0 }) ?? true)
            guard request.quota || request.history else { return }
            // Persist BEFORE sending, so quitting during a request cannot bypass the gate.
            if request.quota { record.nextQuotaAt = date.addingTimeInterval(Self.refreshInterval) }
            if request.history { record.nextHistoryAt = date.addingTimeInterval(Self.historyRefreshInterval) }
        }
        persist()
        isLoading = true
        generation &+= 1
        let requestGeneration = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration {
                    isLoading = false
                    refreshTask = nil
                    expireQuota()
                    updateAvailabilityAndTimer()
                    if !request.quota && !request.history, identityVerified { loadIfNeeded() }
                }
            }
            do {
                let result = try await service.fetchUsage(request)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                apply(result, request: request)
            } catch is CancellationError {
                // A late helper reply must not publish data after stopping.
            } catch {
                guard generation == requestGeneration, !Task.isCancelled else { return }
                applyIssue(.from(error), request: request)
            }
            persist()
        }
    }

    private func apply(_ result: CodexUsageResult, request: CodexUsageRequest) {
        if let issue = result.issue { applyIssue(issue, request: request); return }
        guard let current = result.account else {
            applyIssue(.init(failure: .invalidResponse), request: request)
            return
        }
        let changed = !identityVerified || current != account
        if changed {
            account = current
            identityVerified = true
            stored.nextIdentityAt = nil
            if let key = current.cacheKey { record = stored.accounts[key] ?? .init() }
            else {
                record = .init(nextQuotaAt: stored.anonymousNextQuotaAt, nextHistoryAt: stored.anonymousNextHistoryAt)
            }
            snapshot = record.quota
            history = record.history
            failure = nil
            historyFailure = nil
            // If identity changed during a remote query, charge its attempts to
            // the newly verified account too. Never combine the accounts' data.
            if request.quota { record.nextQuotaAt = now().addingTimeInterval(Self.refreshInterval) }
            if request.history { record.nextHistoryAt = now().addingTimeInterval(Self.historyRefreshInterval) }
        }
        if request.quota {
            if let quota = result.quota { snapshot = quota; record.quota = quota; failure = nil }
            else if let issue = result.quotaIssue {
                failure = issue.failure
                if issue.failure.invalidatesSnapshot { snapshot = nil; record.quota = nil }
            } else { failure = .invalidResponse }
        }
        if request.history {
            if let history = result.history { self.history = history; record.history = history; historyFailure = nil }
            else { historyFailure = result.historyIssue?.failure ?? result.quotaIssue?.failure ?? .invalidResponse }
        }
        let issues = [result.quotaIssue, result.historyIssue].compactMap { $0 }
        if issues.contains(where: { $0.failure == .notSignedIn || $0.failure == .apiKeyAccount }) {
            clearIdentity()
            failure = .notSignedIn
            historyFailure = .notSignedIn
        }
        if let limited = issues.first(where: { $0.failure == .rateLimited }) {
            backOff(limited, source: result.quotaIssue?.failure == .rateLimited ? "quota" : "history")
        } else {
            let source = stored.rateLimitSource
            if (source == "quota" && result.quota != nil) || (source == "history" && result.history != nil)
                || (source == "account" && !request.quota && !request.history) {
                stored.rateLimitDelay = Self.refreshInterval
                stored.rateLimitSource = nil
                stored.blockedUntil = nil
            }
        }
    }

    private func applyIssue(_ issue: CodexUsageIssue, request: CodexUsageRequest) {
        if request.quota || !identityVerified { failure = issue.failure }
        if request.history || !identityVerified { historyFailure = issue.failure }
        if issue.failure == .notSignedIn || issue.failure == .apiKeyAccount {
            clearIdentity()
        } else if issue.failure.invalidatesSnapshot { snapshot = nil; record.quota = nil }
        if issue.failure == .rateLimited {
            backOff(issue, source: request.quota ? "quota" : (request.history ? "history" : "account"))
        }
    }

    private func clearIdentity() {
        if let key = account?.cacheKey {
            record.quota = nil
            record.history = nil
            stored.accounts[key] = record // Keep attempt deadlines through sign-out.
        }
        account = nil
        identityVerified = false
        snapshot = nil
        history = nil
        record = .init()
        stored.nextIdentityAt = now().addingTimeInterval(Self.refreshInterval)
    }

    private func backOff(_ issue: CodexUsageIssue, source: String) {
        stored.rateLimitDelay = min(Self.maximumCacheAge, stored.rateLimitDelay * 2)
        let local = now().addingTimeInterval(stored.rateLimitDelay + max(0, jitter()))
        stored.blockedUntil = max(stored.blockedUntil ?? .distantPast, max(local, issue.retryAt ?? .distantPast))
        stored.rateLimitSource = source
        failure = .rateLimited
        historyFailure = .rateLimited
    }

    private func expireQuota() {
        guard let snapshot else { return }
        let age = now().timeIntervalSince(snapshot.fetchedAt)
        if age >= Self.maximumCacheAge || age < 0 {
            self.snapshot = nil
            record.quota = nil
            if failure != .rateLimited { failure = .dataExpired }
        }
    }

    private func persist() {
        if identityVerified, let key = account?.cacheKey {
            stored.accounts[key] = record
            while stored.accounts.count > 5 {
                let oldest = stored.accounts.filter { $0.key != key }.min {
                    ($0.value.history?.fetchedAt ?? $0.value.quota?.fetchedAt ?? .distantPast)
                        < ($1.value.history?.fetchedAt ?? $1.value.quota?.fetchedAt ?? .distantPast)
                }
                if let oldest { stored.accounts.removeValue(forKey: oldest.key) } else { break }
            }
        } else if identityVerified {
            // Missing email must not let relaunch bypass either query limit.
            // Save only deadlines, never unidentifiable account data.
            stored.anonymousNextQuotaAt = record.nextQuotaAt
            stored.anonymousNextHistoryAt = record.nextHistoryAt
        }
        cacheUnavailable = !storage.save(stored)
    }

    private func updateAvailabilityAndTimer() {
        let date = now()
        retryAt = stored.blockedUntil.flatMap { $0 > date ? $0 : nil }
        let allowed = !isLoading && retryAt == nil
        canRefresh = allowed && ((identityVerified ? record.nextQuotaAt : stored.nextIdentityAt).map { date >= $0 } ?? true)
        canRefreshHistory = allowed && ((identityVerified ? record.nextHistoryAt : stored.nextIdentityAt).map { date >= $0 } ?? true)
        timer?.cancel()
        timer = nil
        guard isRunning else { return }
        var deadline: Date?
        if !isLoading {
            let due = identityVerified
                ? min(record.nextQuotaAt ?? date, record.nextHistoryAt ?? date)
                : (stored.nextIdentityAt ?? date)
            deadline = max(date, max(due, stored.blockedUntil ?? .distantPast))
        }
        if let snapshot {
            let expiry = snapshot.fetchedAt.addingTimeInterval(Self.maximumCacheAge)
            deadline = min(deadline ?? expiry, expiry)
        }
        guard let deadline else { return }
        let sleepUntil = sleepUntil
        timer = Task { [weak self] in
            do { try await sleepUntil(deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.loadIfNeeded()
        }
    }
}
