import Foundation
import Cocoa
import AsyncXPCConnection

@MainActor
final class XPCHelperClient: NSObject {
    static let shared = XPCHelperClient()
    
    private let connectionFactory: @MainActor () -> NSXPCConnection
    private var connectionGeneration: UInt = 0
    
    private var remoteService: RemoteXPCService<BoringNotchXPCHelperProtocol>?
    private var connection: NSXPCConnection?
    private var lastKnownAuthorization: Bool?
    private var monitoringTask: Task<Void, Never>?
    private var deviceBatteryReplies: [UUID: CheckedContinuation<DeviceBatteryResult, Error>] = [:]
    private var deviceBatteryDeadlines: [UUID: Task<Void, Never>] = [:]

    override convenience init() {
        self.init(connectionFactory: {
            NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
        })
    }

    init(connectionFactory: @escaping @MainActor () -> NSXPCConnection) {
        self.connectionFactory = connectionFactory
        super.init()
    }
    
    isolated deinit {
        connection?.invalidate()
        stopMonitoringAccessibilityAuthorization()
    }
    
    // MARK: - Connection Management (Main Actor Isolated)
    
    @MainActor
    private func ensureRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol> {
        if let existing = remoteService {
            return existing
        }
        
        let conn = connectionFactory()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard self?.connectionGeneration == generation else { return }
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard self?.connectionGeneration == generation else { return }
                self?.connection = nil
                self?.remoteService = nil
            }
        }
        
        let service = RemoteXPCService<BoringNotchXPCHelperProtocol>(
            connection: conn,
            remoteInterface: BoringNotchXPCHelperProtocol.self
        )
        
        connection = conn
        remoteService = service
        conn.resume()
        return service
    }
    
    @MainActor
    private func getRemoteService() -> RemoteXPCService<BoringNotchXPCHelperProtocol>? {
        remoteService
    }
    
    @MainActor
    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }

    // MARK: - Monitoring
    func startMonitoringAccessibilityAuthorization(every interval: TimeInterval = 3.0) {
        // Ensure only one monitor exists
        stopMonitoringAccessibilityAuthorization()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                // Call the helper method periodically which will notify on change
                _ = await self?.isAccessibilityAuthorized()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { break }
            }
        }
    }

    func stopMonitoringAccessibilityAuthorization() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    // Expose whether the client is actively monitoring (useful for tests/debug)
    var isMonitoring: Bool {
        return monitoringTask != nil
    }
    
    func fetchDeviceBatteries(_ request: DeviceBatteryRequest) async throws -> DeviceBatteryResult {
        let encoded = try JSONEncoder().encode(request)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                _ = ensureRemoteService()
                deviceBatteryReplies[request.id] = continuation
                deviceBatteryDeadlines[request.id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(18))
                    guard !Task.isCancelled, let self else { return }
                    self.finishDeviceBatteryRequest(request.id, result: .failure(DeviceBatterySourceState.timedOut))
                    self.cancelDeviceBatteryRequest(request.id)
                }
                let proxy = connection?.remoteObjectProxyWithErrorHandler { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.finishDeviceBatteryRequest(request.id, result: .failure(DeviceBatterySourceState.unavailable))
                    }
                } as? BoringNotchXPCHelperProtocol
                guard let proxy else {
                    finishDeviceBatteryRequest(request.id, result: .failure(DeviceBatterySourceState.unavailable))
                    return
                }
                proxy.fetchDeviceBatteries(encoded) { [weak self] data, failure in
                    Task { @MainActor [weak self] in
                        let result: Result<DeviceBatteryResult, Error>
                        if let failure { result = .failure(DeviceBatterySourceState(rawValue: failure) ?? .unavailable) }
                        else if let data, data.count <= 1_048_576,
                                let decoded = try? JSONDecoder().decode(DeviceBatteryResult.self, from: data) {
                            result = .success(decoded)
                        } else { result = .failure(DeviceBatterySourceState.invalidResponse) }
                        self?.finishDeviceBatteryRequest(request.id, result: result)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelDeviceBatteryRequest(request.id) }
        }
    }

    private func finishDeviceBatteryRequest(_ id: UUID, result: Result<DeviceBatteryResult, Error>) {
        deviceBatteryDeadlines.removeValue(forKey: id)?.cancel()
        deviceBatteryReplies.removeValue(forKey: id)?.resume(with: result)
    }

    func cancelDeviceBatteryRequest(_ id: UUID) {
        finishDeviceBatteryRequest(id, result: .failure(DeviceBatterySourceState.cancelled))
        // Never create a new connection merely to cancel an old request.
        guard let service = remoteService else { return }
        Task {
            try? await service.withService { service in service.cancelDeviceBatteryRequest(id.uuidString) }
        }
    }

    // MARK: - Accessibility

    func fetchClaudeUsage(_ request: ClaudeUsageRequest) async throws -> ClaudeUsageResult {
        let service = ensureRemoteService()
        let encoded = try JSONEncoder().encode(request)
        let data: Data = try await service.withContinuation { service, continuation in
            service.fetchClaudeUsage(encoded) { data, failure in
                if let failure {
                    continuation.resume(throwing: ClaudeUsageFailure(rawValue: failure) ?? .connection)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ClaudeUsageFailure.invalidResponse)
                }
            }
        }
        try Task.checkCancellation()
        guard let result = try? JSONDecoder().decode(ClaudeUsageResult.self, from: data) else {
            throw ClaudeUsageFailure.invalidResponse
        }
        return result
    }

    func fetchCodexUsage(_ request: CodexUsageRequest) async throws -> CodexUsageResult {
        let service = ensureRemoteService()
        let encodedRequest = try JSONEncoder().encode(request)
        let data: Data = try await service.withContinuation { service, continuation in
            service.fetchCodexUsage(encodedRequest) { data, failure in
                if let failure {
                    continuation.resume(throwing: CodexUsageFailure(rawValue: failure) ?? .connection)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CodexUsageFailure.invalidResponse)
                }
            }
        }
        try Task.checkCancellation()
        do {
            return try JSONDecoder().decode(CodexUsageResult.self, from: data)
        } catch {
            throw CodexUsageFailure.invalidResponse
        }
    }
    
    func requestAccessibilityAuthorization() {
        Task {
            let service = ensureRemoteService()
            try? await service.withService { service in
                service.requestAccessibilityAuthorization()
            }
        }
    }
    
    func isAccessibilityAuthorized() async -> Bool {
        do {
            let service = ensureRemoteService()
            let result: Bool = try await service.withContinuation { service, continuation in
                service.isAccessibilityAuthorized { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            notifyAuthorizationChange(result)
            return result
        } catch {
            return false
        }
    }
    
    func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        do {
            let service = ensureRemoteService()
            let result: Bool = try await service.withContinuation { service, continuation in
                service.ensureAccessibilityAuthorization(promptIfNeeded) { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            notifyAuthorizationChange(result)
            return result
        } catch {
            return false
        }
    }
    
    // MARK: - Keyboard Brightness
    
    func isKeyboardBrightnessAvailable() async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.isKeyboardBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    func currentKeyboardBrightness() async -> Float? {
        do {
            let service = ensureRemoteService()
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentKeyboardBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    func setKeyboardBrightness(_ value: Float) async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.setKeyboardBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
    
    // MARK: - Screen Brightness
    
    func isScreenBrightnessAvailable() async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.isScreenBrightnessAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            return false
        }
    }
    
    func currentScreenBrightness() async -> Float? {
        do {
            let service = ensureRemoteService()
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentScreenBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            return nil
        }
    }
    
    func setScreenBrightness(_ value: Float) async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            return false
        }
    }
}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
}
