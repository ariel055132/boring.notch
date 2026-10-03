import Foundation
import os
@testable import Boring_Notch

private actor ForecastStub: WeatherServiceProviding {
    let snapshot: WeatherSnapshot
    let now: @MainActor @Sendable () -> Date
    private(set) var calls = 0
    private(set) var requestDates: [Date] = []
    var failure: WeatherFailure?
    private var isPaused = false
    private var pendingResponse: CheckedContinuation<Void, Never>?
    init(snapshot: WeatherSnapshot, now: @escaping @MainActor @Sendable () -> Date) {
        self.snapshot = snapshot
        self.now = now
    }
    func fail(with failure: WeatherFailure?) { self.failure = failure }
    func pauseResponses() { isPaused = true }
    func resumeResponses() {
        isPaused = false
        pendingResponse?.resume()
        pendingResponse = nil
    }
    func forecast(for coordinate: WeatherCoordinate) async throws -> WeatherSnapshot {
        calls += 1
        requestDates.append(await now())
        if isPaused { await withCheckedContinuation { pendingResponse = $0 } }
        try await Task.sleep(for: .milliseconds(20))
        if let failure { throw failure }
        return WeatherSnapshot(current: snapshot.current, hourly: snapshot.hourly, daily: snapshot.daily,
                               timeZone: snapshot.timeZone, fetchedAt: await now())
    }
}

// Exercises the real background scheduler without waiting 3 or 30 minutes.
@MainActor
private final class WeatherTestClock {
    var now = Date(timeIntervalSince1970: 1_791_034_200)
    private var sleepers: [UUID: (Date, CheckedContinuation<Void, Error>)] = [:]

    func advance(by seconds: TimeInterval) {
        now.addTimeInterval(seconds)
        let ready = sleepers.filter { $0.value.0 <= now }
        for (id, (_, continuation)) in ready {
            sleepers.removeValue(forKey: id)
            continuation.resume()
        }
    }

    func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard deadline > now else { return }
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = (deadline, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
            }
        }
    }
}

@MainActor
private final class LocationStub: WeatherLocationProviding {
    var authorization: WeatherLocationAuthorization = .notDetermined
    var calls = 0
    var failure: WeatherFailure?
    var delay: (@MainActor () async -> Void)?
    func locate() async throws -> WeatherCoordinate {
        calls += 1
        await delay?()
        if authorization == .denied { throw WeatherFailure.locationDenied }
        if let failure { throw failure }
        authorization = .allowed
        return WeatherCoordinate(latitude: 25.03, longitude: 121.57)
    }
    func placeName(for coordinate: WeatherCoordinate) async -> String? { "Taipei" }
}

private final class WeatherHTTPStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var data = Data()
        var error: URLError?
    }
    static let reply = OSAllocatedUnfairLock(initialState: Reply())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.reply.withLock { $0 }
        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main
@MainActor
private struct WeatherRegressionChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "WeatherRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }

    static func fixture() -> [String: Any] {
        let start: Double = 1_790_956_800 // 2026-10-03 00:00 Asia/Taipei
        return [
            "timezone": "Asia/Taipei",
            "current": ["time": start + 21 * 3600 + 1800, "temperature_2m": 23.9, "apparent_temperature": 28.9,
                        "relative_humidity_2m": 98, "wind_speed_10m": 5, "weather_code": 0, "is_day": 0],
            "hourly": ["time": (0..<72).map { start + Double($0) * 3600 },
                       "temperature_2m": Array(repeating: 24.0, count: 72),
                       "precipitation_probability": Array(repeating: 30, count: 72),
                       "weather_code": Array(repeating: 2, count: 72), "is_day": Array(repeating: 1, count: 72)],
            "daily": ["time": (0..<7).map { start + Double($0) * 86400 },
                      "temperature_2m_max": Array(repeating: 29.0, count: 7),
                      "temperature_2m_min": Array(repeating: 21.0, count: 7),
                      "precipitation_probability_max": Array(repeating: 60, count: 7),
                      "weather_code": Array(repeating: 61, count: 7)]
        ]
    }

    static func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    static func main() async throws {
        let body = try data(fixture())
        let snapshot = try OpenMeteoWeatherService.decode(body, fetchedAt: Date())
        try expect(snapshot.hourly.count == 24, "Forecast must contain the next 24 hourly slots")
        try expect(snapshot.daily.count == 7, "Forecast must contain seven local days")
        try expect(snapshot.current.temperature == 23.9, "Current temperature must decode")
        try expect(snapshot.current.condition.symbol == "moon.stars.fill", "Clear weather at night must use a night symbol")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = snapshot.timeZone
        try expect(calendar.component(.hour, from: snapshot.daily[0].date) == 0, "Daily dates must preserve local midnight")
        try expect(calendar.component(.day, from: snapshot.daily[0].date) == 3, "UTC conversion must not shift the forecast day")
        try expect(calendar.component(.hour, from: snapshot.hourly[0].time) == 21, "Past hourly slots must be excluded")
        try expect(snapshot.hourLabel(snapshot.hourly[0].time) == "21:00", "Hourly labels must distinguish morning and evening in the forecast's time zone")
        try expect(snapshot.hourly.last!.time.timeIntervalSince(snapshot.hourly.first!.time) == 23 * 3600, "Hourly forecast must stop at the 24-hour horizon")

        let url = try OpenMeteoWeatherService.requestURL(for: WeatherCoordinate(latitude: 25.0331234, longitude: 121.5659876))
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        try expect(query["latitude"] == "25.03" && query["longitude"] == "121.57", "Only approximate coordinates may be sent")
        try expect(query["timezone"] == "auto" && query["timeformat"] == "unixtime", "Use local forecast days and absolute timestamps")
        try expect(query["temperature_unit"] == "celsius" && url.scheme == "https", "Temperature units and transport must be explicit")
        do {
            _ = try OpenMeteoWeatherService.requestURL(for: WeatherCoordinate(latitude: 91, longitude: 0))
            throw NSError(domain: "WeatherRegression", code: 2)
        } catch WeatherFailure.locationUnavailable { checks += 1 }

        for (code, symbol) in [(2, "cloud.sun.fill"), (48, "cloud.fog.fill"), (67, "cloud.sleet.fill"), (86, "cloud.snow.fill"), (97, "cloud.bolt.rain.fill"), (999, "cloud")] {
            try expect(WeatherCondition(code: code).symbol == symbol, "Weather code \(code) must have a safe symbol")
        }
        var optional = fixture()
        var current = optional["current"] as! [String: Any]
        current["apparent_temperature"] = NSNull()
        current["weather_code"] = NSNull()
        optional["current"] = current
        let nullable = try OpenMeteoWeatherService.decode(data(optional), fetchedAt: Date())
        try expect(nullable.current.apparentTemperature == nil && nullable.current.condition.code == -1, "Missing optional observations must not fabricate values")

        var partial = fixture()
        var hourly = partial["hourly"] as! [String: Any]
        var temperatures = hourly["temperature_2m"] as! [Any]
        temperatures[22] = NSNull()
        hourly["temperature_2m"] = temperatures
        partial["hourly"] = hourly
        let missingHour = try OpenMeteoWeatherService.decode(data(partial), fetchedAt: Date())
        try expect(missingHour.hourly.count == 23, "Missing temperatures must not extend the forecast beyond 24 hours")
        hourly["weather_code"] = [0]
        partial["hourly"] = hourly
        try expectInvalid(try data(partial), "Mismatched arrays must be rejected without indexing past their ends")
        try expectInvalid(Data("{}".utf8), "Missing forecast objects must be rejected")
        current["temperature_2m"] = NSNull()
        optional["current"] = current
        try expectInvalid(try data(optional), "Missing current temperature must be rejected")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeatherHTTPStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = OpenMeteoWeatherService(session: session)
        let coordinate = WeatherCoordinate(latitude: 25.03, longitude: 121.57)
        WeatherHTTPStub.reply.withLock { $0 = .init(data: body) }
        try expect(try await service.forecast(for: coordinate).daily.count == 7, "Successful HTTP responses must decode")
        WeatherHTTPStub.reply.withLock { $0 = .init(status: 429) }
        do { _ = try await service.forecast(for: coordinate); throw NSError(domain: "WeatherRegression", code: 3) }
        catch WeatherFailure.serviceUnavailable { checks += 1 }
        WeatherHTTPStub.reply.withLock { $0 = .init(error: URLError(.notConnectedToInternet)) }
        do { _ = try await service.forecast(for: coordinate); throw NSError(domain: "WeatherRegression", code: 4) }
        catch WeatherFailure.network { checks += 1 }

        try await managerLifecycle(snapshot)
        try await failureExpiry(snapshot)
        try await persistentCache(snapshot)
        try await delayedLocation(snapshot)
        print("Passed \(checks) weather regression checks")
    }

    static func expectInvalid(_ body: Data, _ message: String) throws {
        do {
            _ = try OpenMeteoWeatherService.decode(body, fetchedAt: Date())
            try expect(false, message)
        } catch WeatherFailure.invalidResponse { checks += 1 }
    }

    static func waitForRefresh(_ manager: WeatherManager) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while manager.isLoading {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "WeatherRegression", code: 5) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func waitUntil(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "WeatherRegression", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func waitForCalls(_ expected: Int, service: ForecastStub, manager: WeatherManager) async throws {
        try await waitUntil("Expected \(expected) completed weather requests") {
            await service.calls == expected && !manager.isLoading
        }
    }

    static func makeManager(_ snapshot: WeatherSnapshot, clock: WeatherTestClock,
                            location: LocationStub, cacheURL: URL? = nil) -> (WeatherManager, ForecastStub) {
        let service = ForecastStub(snapshot: snapshot, now: { clock.now })
        let manager = WeatherManager(service: service, location: location, cacheURL: cacheURL,
                                     now: { clock.now }, sleepUntil: { try await clock.sleep(until: $0) })
        return (manager, service)
    }

    static func managerLifecycle(_ snapshot: WeatherSnapshot) async throws {
        let clock = WeatherTestClock()
        let location = LocationStub()
        let (manager, service) = makeManager(snapshot, clock: clock, location: location)
        defer { manager.stopBackgroundUpdates() }
        manager.startBackgroundUpdates()
        manager.startBackgroundUpdates()
        manager.loadIfNeeded()
        try expect(location.calls == 0 && manager.snapshot == nil, "App launch and page appearance must not prompt for location")
        manager.refresh()
        manager.refresh()
        try await waitForRefresh(manager)
        try expect(await service.calls == 1, "Concurrent refresh actions must share one request")
        try expect(manager.snapshot != nil && manager.failure == nil, "A successful request must publish weather")
        try await waitUntil("Reverse geocoding should finish") { manager.placeName == "Taipei" }
        try expect(!manager.canRefresh, "Manual refresh must be disabled during the shared cooldown")
        for _ in 0..<10 {
            manager.loadIfNeeded()
            manager.refresh()
            manager.startBackgroundUpdates()
        }
        try expect(await service.calls == 1 && location.calls == 1, "Page changes, clicks, and repeated starts must not bypass the rate limit")
        clock.advance(by: 179.999)
        manager.refresh()
        try expect(await service.calls == 1, "No API call may start before three minutes")
        clock.advance(by: 0.001)
        try await waitForCalls(2, service: service, manager: manager)
        try expect(manager.snapshot?.fetchedAt == clock.now, "Background updates must run at three minutes without a WeatherView")
        clock.advance(by: 180)
        try await waitForCalls(3, service: service, manager: manager)
        let dates = await service.requestDates
        try expect(zip(dates, dates.dropFirst()).allSatisfy { $1.timeIntervalSince($0) >= 180 },
                   "All API request start times must be at least three minutes apart")

        manager.stopBackgroundUpdates()
        clock.advance(by: 600)
        try await Task.sleep(for: .milliseconds(30))
        try expect(await service.calls == 3, "Stopping the app lifecycle must stop background requests")
        manager.startBackgroundUpdates()
        manager.loadIfNeeded()
        try await waitForCalls(4, service: service, manager: manager)
        try expect(await service.calls == 4, "Waking after missed intervals must make one update, not replay missed requests")

        let deniedLocation = LocationStub()
        deniedLocation.authorization = .denied
        let (denied, deniedService) = makeManager(snapshot, clock: clock, location: deniedLocation)
        defer { denied.stopBackgroundUpdates() }
        denied.startBackgroundUpdates()
        try expect(denied.failure == .locationDenied, "Denied permission must expose a recovery state")
        denied.refresh()
        try expect(await deniedService.calls == 0, "Denied location must never request weather for a fabricated location")
        deniedLocation.authorization = .allowed
        denied.loadIfNeeded()
        try await waitForCalls(1, service: deniedService, manager: denied)
        try expect(denied.failure == nil && denied.snapshot != nil, "Granting permission in Settings must recover")

        let unavailableLocation = LocationStub()
        unavailableLocation.authorization = .allowed
        unavailableLocation.failure = .locationUnavailable
        let (unavailable, unavailableService) = makeManager(snapshot, clock: clock, location: unavailableLocation)
        defer { unavailable.stopBackgroundUpdates() }
        unavailable.startBackgroundUpdates()
        try await waitForRefresh(unavailable)
        unavailable.refresh()
        try expect(unavailableLocation.calls == 1 && !unavailable.canRefresh, "Location failures must also respect the retry interval")
        try expect(await unavailableService.calls == 0, "Failed location must not reach the weather API")
        unavailableLocation.failure = nil
        clock.advance(by: 180)
        try await waitForCalls(1, service: unavailableService, manager: unavailable)
        try expect(unavailable.failure == nil, "A subsequent background attempt must recover from location failure")
    }

    static func failureExpiry(_ snapshot: WeatherSnapshot) async throws {
        let clock = WeatherTestClock()
        let location = LocationStub()
        location.authorization = .allowed
        let (manager, service) = makeManager(snapshot, clock: clock, location: location)
        defer { manager.stopBackgroundUpdates() }
        manager.startBackgroundUpdates()
        try await waitForCalls(1, service: service, manager: manager)
        let lastSuccess = manager.snapshot!.fetchedAt
        await service.fail(with: .network)
        clock.advance(by: 180)
        try await waitForCalls(2, service: service, manager: manager)
        try expect(manager.failure == .network && manager.snapshot?.fetchedAt == lastSuccess,
                   "A failed update must retain the last successful data and timestamp")
        manager.refresh()
        manager.loadIfNeeded()
        try expect(await service.calls == 2, "Failures and manual retry must not bypass the cooldown")

        // Simulate sleeping through several intervals: one retry, not a burst of missed calls.
        clock.advance(by: 1619)
        try await waitForCalls(3, service: service, manager: manager)
        try expect(manager.snapshot?.fetchedAt == lastSuccess, "The last successful weather must remain visible at 29:59")
        clock.advance(by: 1)
        try await waitUntil("Old weather should expire exactly at thirty minutes") { manager.snapshot == nil }
        try expect(manager.failure == .dataExpired, "Expired weather must present an unavailable state")
        try expect(await service.calls == 3, "Expiring a cache must not itself trigger an early API request")

        await service.fail(with: nil)
        clock.advance(by: 179)
        try await waitForCalls(4, service: service, manager: manager)
        try expect(manager.failure == nil && manager.snapshot?.fetchedAt == clock.now,
                   "The next successful retry must restore weather with a new success timestamp")

        // A response that never arrives must not keep an old forecast on screen.
        await service.pauseResponses()
        clock.advance(by: 1799)
        try await waitUntil("Delayed request should start") { await service.calls == 5 }
        try expect(manager.isLoading && manager.snapshot != nil, "In-flight updates may retain weather younger than thirty minutes")
        clock.advance(by: 1)
        try await waitUntil("Expiration must run even while a response is pending") { manager.snapshot == nil }
        try expect(manager.isLoading && manager.failure == .dataExpired, "A pending response must not prevent the unavailable state")
        clock.advance(by: 180)
        manager.refresh()
        try expect(await service.calls == 5, "A pending request must not overlap another API request")
        await service.resumeResponses()
        try await waitForRefresh(manager)
        try expect(manager.failure == nil && manager.snapshot?.fetchedAt == clock.now, "A late successful response must restore the page")
    }

    static func persistentCache(_ snapshot: WeatherSnapshot) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("weather-cache-checks-\(UUID())")
        let url = directory.appendingPathComponent("weather.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = WeatherTestClock()
        let location = LocationStub()
        location.authorization = .allowed
        let (original, originalService) = makeManager(snapshot, clock: clock, location: location, cacheURL: url)
        original.startBackgroundUpdates()
        try await waitForCalls(1, service: originalService, manager: original)
        try await waitUntil("Region name should be cached") { original.placeName == "Taipei" }
        let lastSuccess = original.snapshot!.fetchedAt
        try expect(FileManager.default.fileExists(atPath: url.path), "Successful weather must be written to a persistent cache")
        original.stopBackgroundUpdates()

        clock.advance(by: 30)
        let (restarted, restartedService) = makeManager(snapshot, clock: clock, location: location, cacheURL: url)
        defer { restarted.stopBackgroundUpdates() }
        try expect(restarted.snapshot?.fetchedAt == lastSuccess && restarted.placeName == "Taipei",
                   "Relaunch must restore unexpired weather and its region")
        await restartedService.fail(with: .network)
        restarted.startBackgroundUpdates()
        restarted.startBackgroundUpdates()
        try await waitForCalls(1, service: restartedService, manager: restarted)
        try expect(restarted.failure == .network && restarted.snapshot?.fetchedAt == lastSuccess,
                   "Every process launch must fetch once even with fresh cache, retaining it if that fetch fails")
        restarted.refresh()
        try expect(await restartedService.calls == 1, "The relaunched process must enforce its own cooldown")
        restarted.stopBackgroundUpdates()

        clock.advance(by: 1770)
        let (expired, expiredService) = makeManager(snapshot, clock: clock, location: location, cacheURL: url)
        defer { expired.stopBackgroundUpdates() }
        try expect(expired.snapshot == nil && expired.failure == .dataExpired, "Relaunch at thirty minutes must reject old disk cache")
        try expect(!FileManager.default.fileExists(atPath: url.path), "Expired cache must be removed from disk")
        expired.startBackgroundUpdates()
        try await waitForCalls(1, service: expiredService, manager: expired)
        try expect(expired.failure == nil && expired.snapshot?.fetchedAt == clock.now, "Relaunch must still fetch when cache has expired")
        expired.stopBackgroundUpdates()

        clock.advance(by: -60)
        let (futureCache, _) = makeManager(snapshot, clock: clock, location: location, cacheURL: url)
        try expect(futureCache.snapshot == nil, "A clock rollback must not make a future-dated cache valid indefinitely")
        try Data("corrupt cache".utf8).write(to: url)
        let (corrupt, corruptService) = makeManager(snapshot, clock: clock, location: location, cacheURL: url)
        defer { corrupt.stopBackgroundUpdates() }
        try expect(corrupt.snapshot == nil, "A corrupt cache must be ignored safely")
        corrupt.startBackgroundUpdates()
        try await waitForCalls(1, service: corruptService, manager: corrupt)
        try expect(corrupt.failure == nil, "A corrupt cache must not prevent an API refresh")
    }

    static func delayedLocation(_ snapshot: WeatherSnapshot) async throws {
        let clock = WeatherTestClock()
        let location = LocationStub()
        location.authorization = .allowed
        var releaseLocation: CheckedContinuation<Void, Never>?
        location.delay = { await withCheckedContinuation { releaseLocation = $0 } }
        let (manager, service) = makeManager(snapshot, clock: clock, location: location)
        defer { manager.stopBackgroundUpdates() }
        manager.startBackgroundUpdates()
        try await waitUntil("Location should be requested") { location.calls == 1 }
        clock.advance(by: 200)
        manager.loadIfNeeded()
        try expect(await service.calls == 0 && location.calls == 1, "A slow location request must be coalesced")
        location.delay = nil
        releaseLocation?.resume()
        try await waitForCalls(1, service: service, manager: manager)
        clock.advance(by: 179)
        manager.refresh()
        try expect(await service.calls == 1, "The cooldown must begin at API dispatch, not before a long permission/location wait")
        clock.advance(by: 1)
        try await waitForCalls(2, service: service, manager: manager)
        try expect(manager.snapshot?.fetchedAt == clock.now, "Background timing must recover after delayed location")
    }
}
