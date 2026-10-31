import Foundation

actor DeviceBatteryProbe {
    static let shared = DeviceBatteryProbe()
    private struct Work {
        var token = UUID()
        var task: Task<DeviceBatterySourceResult, Never>
        var owners: Set<UUID>
    }
    private var work: [DeviceKind: Work] = [:]
    private var cancelled: Set<UUID> = []
    private let read: @Sendable (DeviceKind) async -> DeviceBatterySourceResult

    init(read: @escaping @Sendable (DeviceKind) async -> DeviceBatterySourceResult = { source in
        switch source {
        case .airPods: await AirPodsBatteryReader().read()
        }
    }) { self.read = read }

    func fetch(_ request: DeviceBatteryRequest) async -> DeviceBatteryResult {
        if cancelled.remove(request.id) != nil { return .init(sources: []) }
        let sources = DeviceKind.allCases.filter { request.sources.contains($0) }
        var tasks: [(DeviceKind, Task<DeviceBatterySourceResult, Never>)] = []
        for source in sources {
            // A rapid disable/enable waits for the cancelled process to be reaped,
            // then starts fresh work instead of inheriting its cancelled result.
            while let abandoned = work[source], abandoned.owners.isEmpty {
                _ = await abandoned.task.value
                removeUnownedWork(source, token: abandoned.token)
            }
            if cancelled.contains(request.id) { break }
            if var running = work[source] {
                running.owners.insert(request.id)
                work[source] = running
                tasks.append((source, running.task))
            } else {
                let task = Task { [read] in await read(source) }
                work[source] = .init(task: task, owners: [request.id])
                tasks.append((source, task))
            }
        }
        var results: [DeviceBatterySourceResult] = []
        for (source, task) in tasks {
            results.append(await task.value)
            // Another request can join while suspended. Release only our ownership.
            if var running = work[source], running.owners.remove(request.id) != nil {
                if running.owners.isEmpty { work[source] = nil } else { work[source] = running }
            }
        }
        let wasCancelled = cancelled.remove(request.id) != nil
        return .init(sources: wasCancelled ? [] : results)
    }

    func cancel(_ id: UUID) {
        // Retain a bounded tombstone to handle cancellation arriving before fetch.
        if cancelled.count > 128 { cancelled.removeAll() }
        cancelled.insert(id)
        for source in DeviceKind.allCases {
            guard var running = work[source], running.owners.remove(id) != nil else { continue }
            if running.owners.isEmpty {
                running.task.cancel()
                // Keep the cancelled work until it reaps its process; new requests
                // await its result instead of starting another process concurrently.
                work[source] = running
                let task = running.task
                let token = running.token
                Task {
                    _ = await task.value
                    self.removeUnownedWork(source, token: token)
                }
            } else { work[source] = running }
        }
    }

    private func removeUnownedWork(_ source: DeviceKind, token: UUID) {
        if work[source]?.token == token && work[source]?.owners.isEmpty == true { work[source] = nil }
    }
}
