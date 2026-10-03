import Combine
import Foundation

@MainActor
final class WeatherManager: ObservableObject {
    static let shared = WeatherManager(cacheURL: FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("boring.notch/weather-v1.json"))
    static let refreshInterval: TimeInterval = 3 * 60
    static let maximumCacheAge: TimeInterval = 30 * 60

    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var placeName = String(localized: "Current location")
    @Published private(set) var isLoading = false
    @Published private(set) var failure: WeatherFailure?
    @Published private(set) var canRefresh = true

    private let service: any WeatherServiceProviding
    private let location: any WeatherLocationProviding
    private let cacheURL: URL?
    private let now: @MainActor () -> Date
    private let sleepUntil: @MainActor (Date) async throws -> Void
    private var refreshTask: Task<Void, Never>?
    private var placeNameTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var isRunning = false
    private var nextRequestAt: Date?
    private var coordinate: WeatherCoordinate?

    init(service: any WeatherServiceProviding = OpenMeteoWeatherService(),
         location: any WeatherLocationProviding = WeatherLocationService(),
         cacheURL: URL? = nil,
         now: @escaping @MainActor () -> Date = { Date() },
         sleepUntil: @escaping @MainActor (Date) async throws -> Void = { deadline in
             try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
         }) {
        self.service = service
        self.location = location
        self.cacheURL = cacheURL
        self.now = now
        self.sleepUntil = sleepUntil
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode(CachedWeather.self, from: data) {
            snapshot = saved.snapshot
            placeName = saved.placeName
            expireSnapshot(at: now())
        }
    }

    isolated deinit {
        backgroundTask?.cancel()
        refreshTask?.cancel()
        placeNameTask?.cancel()
    }

    // Owned by the app lifecycle, so closing a notch or changing tabs cannot stop updates.
    func startBackgroundUpdates() {
        guard !isRunning else { return }
        isRunning = true
        loadIfNeeded()
    }

    func stopBackgroundUpdates() {
        isRunning = false
        backgroundTask?.cancel()
        backgroundTask = nil
        refreshTask?.cancel()
        placeNameTask?.cancel()
    }

    // Launch, wake, and page appearance never open a location permission prompt.
    func loadIfNeeded() {
        requestRefresh(allowPermissionPrompt: false)
    }

    // Explicit actions share the same rate limit as background updates.
    func refresh() {
        requestRefresh(allowPermissionPrompt: true)
    }

    private func requestRefresh(allowPermissionPrompt: Bool) {
        let date = now()
        expireSnapshot(at: date)
        defer {
            canRefresh = !isLoading && (nextRequestAt.map { date >= $0 } ?? true)
            scheduleNextUpdate()
        }
        guard !isLoading else { return }
        guard location.authorization != .denied else {
            failure = .locationDenied
            return
        }
        if failure == .locationDenied { failure = nil }
        guard allowPermissionPrompt || location.authorization == .allowed else { return }
        guard nextRequestAt.map({ date >= $0 }) ?? true else { return }

        isLoading = true
        nextRequestAt = date.addingTimeInterval(Self.refreshInterval)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isLoading = false
                refreshTask = nil
                expireSnapshot(at: now())
                canRefresh = nextRequestAt.map { now() >= $0 } ?? true
                scheduleNextUpdate()
            }
            do {
                let newCoordinate = try await location.locate()
                try Task.checkCancellation()
                // Count from the actual API request, even if permission/location took time.
                nextRequestAt = now().addingTimeInterval(Self.refreshInterval)
                scheduleNextUpdate()
                let updated = try await service.forecast(for: newCoordinate)
                try Task.checkCancellation()
                snapshot = updated
                failure = nil
                if coordinate != newCoordinate || placeName == String(localized: "Current location") {
                    coordinate = newCoordinate
                    placeName = String(localized: "Current location")
                    placeNameTask?.cancel()
                    placeNameTask = Task { [weak self, location] in
                        let name = await location.placeName(for: newCoordinate)
                        guard !Task.isCancelled, let self, coordinate == newCoordinate, let name else { return }
                        placeName = name
                        saveSnapshot()
                    }
                }
                saveSnapshot()
            } catch is CancellationError {
                // Cancellation does not change the last successful update time.
            } catch {
                failure = error as? WeatherFailure ?? .network
            }
        }
    }

    private func scheduleNextUpdate() {
        backgroundTask?.cancel()
        backgroundTask = nil
        guard isRunning else { return }
        let date = now()
        var deadline = date.addingTimeInterval(Self.refreshInterval)
        if let nextRequestAt, nextRequestAt > date { deadline = nextRequestAt }
        // Expire stale data on time, including while a network request is still pending.
        if let snapshot {
            deadline = min(deadline, snapshot.fetchedAt.addingTimeInterval(Self.maximumCacheAge))
        }
        let sleepUntil = sleepUntil
        backgroundTask = Task { [weak self] in
            do { try await sleepUntil(deadline) } catch { return }
            guard !Task.isCancelled, let self else { return }
            backgroundTask = nil
            loadIfNeeded()
        }
    }

    private func expireSnapshot(at date: Date) {
        guard let snapshot else { return }
        let age = date.timeIntervalSince(snapshot.fetchedAt)
        guard age >= Self.maximumCacheAge || age < 0 else { return }
        self.snapshot = nil
        failure = .dataExpired
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
    }

    private func saveSnapshot() {
        guard let snapshot, let cacheURL,
              let data = try? JSONEncoder().encode(CachedWeather(snapshot: snapshot, placeName: placeName)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private struct CachedWeather: Codable {
        let snapshot: WeatherSnapshot
        let placeName: String
    }
}
