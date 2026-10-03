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
    
    // MARK: - Accessibility

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
