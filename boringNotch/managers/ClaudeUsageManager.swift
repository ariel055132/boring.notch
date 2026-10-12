import Combine
import Foundation

struct ClaudeUsageStoredState: Codable {
    var version = 1
    var snapshot: ClaudeUsageSnapshot?
    var nextUsageAt: Date?
    var nextIdentityAt: Date?
    var blockedUntil: Date?
    var rateLimitDelay: TimeInterval = 300
}

@MainActor
protocol ClaudeUsageStoring {
    func load() -> ClaudeUsageStoredState
    func save(_ state: ClaudeUsageStoredState) -> Bool
}

struct ClaudeUsageFileStore: ClaudeUsageStoring {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory.appendingPathComponent("boringNotch/ClaudeUsage.json")
    }

    func load() -> ClaudeUsageStoredState {
        guard let data = try? Data(contentsOf: url), data.count <= 100_000,
              let state = try? JSONDecoder().decode(ClaudeUsageStoredState.self, from: data),
              state.version == 1, state.rateLimitDelay.isFinite,
              (300...1800).contains(state.rateLimitDelay) else { return .init() }
        if let snapshot = state.snapshot {
            guard !snapshot.account.credentialID.isEmpty, snapshot.windows.count <= 6,
                  !snapshot.windows.isEmpty,
                  Set(snapshot.windows.map(\.id)).count == snapshot.windows.count,
                  snapshot.windows.allSatisfy({ $0.usedPercent.map { $0.isFinite && $0 >= 0 } ?? true }) else {
                return .init(nextUsageAt: state.nextUsageAt, nextIdentityAt: state.nextIdentityAt,
                             blockedUntil: state.blockedUntil, rateLimitDelay: state.rateLimitDelay)
            }
        }
        return state
    }

    func save(_ state: ClaudeUsageStoredState) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}

@MainActor
final class ClaudeUsageManager: ObservableObject {
    static let shared = ClaudeUsageManager()
    static let refreshInterval: TimeInterval = 5 * 60
    static let maximumCacheAge: TimeInterval = 30 * 60

    @Published private(set) var snapshot: ClaudeUsageSnapshot?
    @Published private(set) var account: ClaudeUsageAccount?
    @Published private(set) var failure: ClaudeUsageFailure?
    @Published private(set) var isLoading = false
    @Published private(set) var canRefresh = false
    @Published private(set) var cacheUnavailable = false
    @Published private(set) var retryAt: Date?
    @Published private(set) var nextRefreshAt: Date?

    private let service: any ClaudeUsageServiceProviding
    private let storage: any ClaudeUsageStoring
    private let now: @MainActor () -> Date
    private let sleepUntil: @MainActor (Date) async throws -> Void
    private let jitter: @MainActor () -> TimeInterval
    private var stored: ClaudeUsageStoredState
    private var identityVerified = false
    private var refreshTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var isRunning = false
    private var generation: UInt = 0

    init(service: any ClaudeUsageServiceProviding = ClaudeUsageService(),
         storage: any ClaudeUsageStoring = ClaudeUsageFileStore(),
         now: @escaping @MainActor () -> Date = { Date() },
         sleepUntil: @escaping @MainActor (Date) async throws -> Void = { deadline in
             try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
         }, jitter: @escaping @MainActor () -> TimeInterval = { Double.random(in: 0...30) }) {
        self.service = service
        self.storage = storage
        self.now = now
        self.sleepUntil = sleepUntil
        self.jitter = jitter
        stored = storage.load()
        // Never display disk data before verifying the currently signed-in identity.
        if let until = stored.blockedUntil, until > now() {
            failure = .rateLimited
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

    func connect() {
        guard !isLoading else { return }
        identityVerified = false
        snapshot = nil
        stored.nextIdentityAt = nil
        // This only bypasses the local identity gate, never the HTTP cooldown.
        loadIfNeeded(allowKeychainPrompt: true)
    }

    func loadIfNeeded(allowKeychainPrompt: Bool = false) {
        expireSnapshot()
        defer { updateAvailabilityAndTimer() }
        guard !isLoading else { return }
        let date = now()
        let request: ClaudeUsageRequest
        if !identityVerified {
            guard stored.nextIdentityAt.map({ date >= $0 }) ?? true else { return }
            request = .init(allowKeychainPrompt: allowKeychainPrompt)
            stored.nextIdentityAt = date.addingTimeInterval(Self.refreshInterval)
        } else {
            guard usageDeadline <= date else { return }
            request = .init(usage: true)
            stored.nextUsageAt = date.addingTimeInterval(Self.refreshInterval)
        }
        // Persist the attempt before sending so relaunches cannot bypass throttling.
        persist()
        isLoading = true
        generation &+= 1
        let currentGeneration = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == currentGeneration {
                    isLoading = false
                    refreshTask = nil
                    expireSnapshot()
                    updateAvailabilityAndTimer()
                    if !request.usage, identityVerified { loadIfNeeded() }
                }
            }
            do {
                let result = try await service.fetchUsage(request)
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }
                apply(result, request: request)
            } catch is CancellationError {
                // A late XPC reply must not publish data after stopping.
            } catch {
                guard generation == currentGeneration, !Task.isCancelled else { return }
                applyIssue(.from(error))
            }
            persist()
        }
    }

    private func apply(_ result: ClaudeUsageResult, request: ClaudeUsageRequest) {
        if let current = result.account {
            if current != account || !identityVerified {
                account = current
                identityVerified = true
                stored.nextIdentityAt = nil
                if stored.snapshot?.account != current { stored.snapshot = nil }
                snapshot = stored.snapshot
                failure = retryAt == nil ? nil : .rateLimited
            }
        }
        if let issue = result.issue { applyIssue(issue); return }
        guard let current = result.account else { applyIssue(.init(failure: .invalidResponse)); return }
        guard request.usage else { return }
        guard let value = result.snapshot, value.account == current, !value.windows.isEmpty else {
            applyIssue(.init(failure: .invalidResponse))
            return
        }
        snapshot = value
        stored.snapshot = value
        failure = nil
        stored.blockedUntil = nil
        stored.rateLimitDelay = Self.refreshInterval
    }

    private func applyIssue(_ issue: ClaudeUsageIssue) {
        failure = issue.failure
        if issue.failure.invalidatesSnapshot { snapshot = nil; stored.snapshot = nil }
        if issue.failure.needsConnection {
            account = nil
            identityVerified = false
            stored.nextIdentityAt = now().addingTimeInterval(Self.refreshInterval)
        }
        if issue.failure == .rateLimited {
            stored.rateLimitDelay = min(1800, max(Self.refreshInterval, stored.rateLimitDelay) * 2)
            let local = now().addingTimeInterval(stored.rateLimitDelay + max(0, jitter()))
            stored.blockedUntil = max(local, issue.retryAt ?? local, stored.blockedUntil ?? local)
        }
    }

    private var usageDeadline: Date {
        max(stored.nextUsageAt ?? .distantPast, stored.blockedUntil ?? .distantPast)
    }

    private func expireSnapshot() {
        guard let value = stored.snapshot else { return }
        let age = now().timeIntervalSince(value.fetchedAt)
        guard age >= Self.maximumCacheAge || age < -60 else { return }
        stored.snapshot = nil
        snapshot = nil
        if failure == nil { failure = .dataExpired }
        persist()
    }

    private func persist() { cacheUnavailable = !storage.save(stored) }

    private func updateAvailabilityAndTimer() {
        timer?.cancel()
        timer = nil
        let date = now()
        retryAt = stored.blockedUntil.flatMap { $0 > date ? $0 : nil }
        let deadline = identityVerified ? usageDeadline : (stored.nextIdentityAt ?? .distantPast)
        canRefresh = !isLoading && deadline <= date
        nextRefreshAt = deadline > date ? deadline : nil
        guard isRunning else { return }
        var deadlines: [Date] = []
        if !isLoading { deadlines.append(max(date, deadline)) }
        if let snapshot {
            deadlines.append(snapshot.fetchedAt.addingTimeInterval(Self.maximumCacheAge))
        }
        guard let next = deadlines.min() else { return }
        timer = Task { [weak self, sleepUntil] in
            do { try await sleepUntil(next) } catch { return }
            guard !Task.isCancelled, let self, isRunning else { return }
            loadIfNeeded()
        }
    }
}
