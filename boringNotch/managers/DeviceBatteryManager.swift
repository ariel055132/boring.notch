import Combine
import Foundation

@MainActor
final class DeviceBatteryManager: ObservableObject {
    static let shared = DeviceBatteryManager()
    static let refreshInterval: TimeInterval = 60
    static let minimumRetryInterval: TimeInterval = 15

    @Published private(set) var devices: [DeviceBatterySnapshot] = []
    @Published private(set) var sourceStates: [DeviceKind: DeviceBatterySourceState] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var canRefresh = true
    private(set) var isRunning = false

    private let fetch: @MainActor (DeviceBatteryRequest) async throws -> DeviceBatteryResult
    private let cancel: @MainActor (UUID) -> Void
    private let now: @MainActor () -> Date
    private let sleepUntil: @MainActor (Date) async throws -> Void
    private var nextRequest: [DeviceKind: Date] = [:]
    private var failures: [DeviceKind: Int] = [:]
    private var lastRequest: Date?
    private var request: DeviceBatteryRequest?
    private var refreshTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var generation: UInt = 0

    init(fetch: @escaping @MainActor (DeviceBatteryRequest) async throws -> DeviceBatteryResult = {
             try await XPCHelperClient.shared.fetchDeviceBatteries($0)
         }, cancel: @escaping @MainActor (UUID) -> Void = {
             XPCHelperClient.shared.cancelDeviceBatteryRequest($0)
         }, now: @escaping @MainActor () -> Date = { Date() },
         sleepUntil: @escaping @MainActor (Date) async throws -> Void = {
             try await Task.sleep(for: .seconds(max(0, $0.timeIntervalSinceNow)))
         }) {
        self.fetch = fetch; self.cancel = cancel; self.now = now; self.sleepUntil = sleepUntil
    }

    isolated deinit {
        backgroundTask?.cancel()
        refreshTask?.cancel()
        if let request { cancel(request.id) }
    }

    func startBackgroundUpdates() {
        guard !isRunning else { return }
        isRunning = true
        nextRequest.removeAll()
        refreshIfNeeded()
    }

    func stopBackgroundUpdates(clear: Bool = false) {
        isRunning = false
        generation &+= 1
        backgroundTask?.cancel(); backgroundTask = nil
        refreshTask?.cancel(); refreshTask = nil
        if let request { cancel(request.id) }
        request = nil
        isLoading = false
        if clear { devices = []; sourceStates = [:]; failures = [:]; lastRequest = nil }
        else {
            for index in devices.indices { devices[index].markStale(connection: .unknown) }
        }
    }

    func refreshIfNeeded(manual: Bool = false) {
        let date = now()
        expire(at: date)
        guard isRunning, !isLoading else { return }
        if let lastRequest, date < lastRequest {
            self.lastRequest = nil
            nextRequest.removeAll()
        }
        let elapsed = lastRequest.map { date.timeIntervalSince($0) } ?? .infinity
        canRefresh = elapsed >= Self.minimumRetryInterval || elapsed < 0
        let sources = DeviceKind.allCases.filter { source in
            if manual && canRefresh { return true }
            return nextRequest[source].map { date >= $0 } ?? true
        }
        guard !sources.isEmpty else { schedule(); return }
        let request = DeviceBatteryRequest(sources: sources)
        self.request = request
        let generation = generation
        lastRequest = date
        isLoading = true
        canRefresh = false
        for source in sources {
            if sourceStates[source] == nil { sourceStates[source] = .loading }
            nextRequest[source] = date.addingTimeInterval(Self.refreshInterval)
        }
        schedule()
        refreshTask = Task { [weak self, fetch] in
            let result: DeviceBatteryResult
            do { result = try await fetch(request) }
            catch { result = .init(sources: sources.map { .init(source: $0, state: .unavailable) }) }
            guard let self, !Task.isCancelled, generation == self.generation, self.isRunning else { return }
            let completedAt = self.now()
            for source in sources {
                let report = result.sources.first { $0.source == source }
                    ?? .init(source: source, state: .invalidResponse)
                self.apply(report, at: completedAt)
                let healthy = report.state == .available && !report.devices.isEmpty
                self.failures[source] = healthy ? 0 : min(3, (self.failures[source] ?? 0) + 1)
                let delay = min(300, Self.refreshInterval * pow(2, Double(self.failures[source] ?? 0)))
                self.nextRequest[source] = completedAt.addingTimeInterval(delay)
            }
            self.expire(at: completedAt)
            self.request = nil
            self.refreshTask = nil
            self.isLoading = false
            self.canRefresh = completedAt.timeIntervalSince(date) >= Self.minimumRetryInterval
            self.schedule()
        }
    }

    private func apply(_ report: DeviceBatterySourceResult, at date: Date) {
        sourceStates[report.source] = report.state
        var saved = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let returned = Set(report.devices.map(\.id))
        for id in Array(saved.keys) where saved[id]?.kind == report.source && !returned.contains(id) {
            saved[id]?.markStale(connection: report.state == .noDevices || report.state == .bluetoothOff
                || report.state == .available ? .disconnected : .unknown)
        }
        for var device in report.devices where device.kind == report.source {
            // Missing/invalid components retain their own previous timestamp, never the
            // timestamp of a different ear or a successful source-wide query.
            if let old = saved[device.id] {
                for var reading in old.components {
                    if !device.components.contains(where: { $0.component == reading.component && $0.percent != nil }) {
                        device.components.removeAll { $0.component == reading.component }
                        reading.isStale = true
                        reading.chargingState = .unknown
                        device.components.append(reading)
                    }
                }
            }
            for index in device.components.indices {
                if let percent = device.components[index].percent, !(0...100).contains(percent) {
                    device.components[index].percent = nil
                    device.components[index].chargingState = .unknown
                }
            }
            device.expire(at: date)
            saved[device.id] = device
        }
        devices = saved.values.sorted { $0.id < $1.id }
    }

    private func expire(at date: Date) {
        for index in devices.indices { devices[index].expire(at: date) }
    }

    private func schedule() {
        backgroundTask?.cancel(); backgroundTask = nil
        guard isRunning else { return }
        let date = now()
        var deadlines = nextRequest.values.filter { $0 > date }
        if let lastRequest {
            let retry = lastRequest.addingTimeInterval(Self.minimumRetryInterval)
            if retry > date { deadlines.append(retry) }
        }
        for reading in devices.flatMap(\.components) where reading.percent != nil {
            let expiry = reading.readAt.addingTimeInterval(DeviceBatterySnapshot.maximumAge)
            if expiry > date { deadlines.append(expiry) }
        }
        let deadline = deadlines.min() ?? date.addingTimeInterval(Self.refreshInterval)
        backgroundTask = Task { [weak self, sleepUntil] in
            do { try await sleepUntil(deadline) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.backgroundTask = nil
            self.refreshIfNeeded()
            // An in-flight source may overlap an expiry or the retry cooldown.
            if self.isLoading { self.schedule() }
        }
    }
}
