import Foundation
import LocalAuthentication
import Security

struct ClaudeUsageKeychainClient {
    let getInteractionAllowed: (inout Bool) -> OSStatus
    let setInteractionAllowed: (Bool) -> OSStatus
    let copyMatching: (CFDictionary, inout CFTypeRef?) -> OSStatus

    // Claude Code stores its credential in the legacy login Keychain. Its ACL
    // prompts are not controlled by LAContext; these deprecated APIs are still
    // required for that store. Keep the exception scoped to this adapter.
    #if compiler(>=6.4)
    @diagnose(DeprecatedDeclaration, as: ignored)
    #endif
    static var live: Self {
        .init(getInteractionAllowed: { allowed in
                  var value = DarwinBoolean(false)
                  let status = SecKeychainGetUserInteractionAllowed(&value)
                  allowed = value.boolValue
                  return status
              },
              setInteractionAllowed: { SecKeychainSetUserInteractionAllowed($0) },
              copyMatching: { SecItemCopyMatching($0, &$1) })
    }
}

enum ClaudeUsageKeychain {
    // The legacy interaction switch is process-wide. All Keychain reads in this
    // helper must hold this lock until the original policy has been restored.
    private static let interactionLock = NSLock()

    static func read(allowInteraction: Bool,
                     client: ClaudeUsageKeychainClient = .live) throws -> Data {
        try withInteraction(allowInteraction, client: client) {
            let context = LAContext()
            context.interactionNotAllowed = !allowInteraction
            context.localizedReason = String(localized: "Read your Claude subscription usage")
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Claude Code-credentials",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context
            ]
            var item: CFTypeRef?
            let status = client.copyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data else { throw ClaudeUsageFailure.notSignedIn }
                return data
            case errSecItemNotFound: throw ClaudeUsageFailure.notSignedIn
            case errSecInteractionNotAllowed, errSecInteractionRequired,
                 errSecAuthFailed, errSecUserCanceled, errSecNotAvailable,
                 OSStatus(CSSMERR_CSP_NO_USER_INTERACTION), OSStatus(CSSMERR_CSP_IN_DARK_WAKE),
                 OSStatus(CSSMERR_CSP_OPERATION_AUTH_DENIED):
                throw ClaudeUsageFailure.permissionRequired
            default: throw ClaudeUsageFailure.connection
            }
        }
    }

    static func withInteraction<T>(_ allowInteraction: Bool,
                                   client: ClaudeUsageKeychainClient = .live,
                                   operation: () throws -> T) throws -> T {
        interactionLock.lock()
        defer { interactionLock.unlock() }

        var previousInteraction = false
        guard client.getInteractionAllowed(&previousInteraction) == errSecSuccess else {
            throw ClaudeUsageFailure.permissionRequired
        }
        guard client.setInteractionAllowed(allowInteraction) == errSecSuccess else {
            _ = client.setInteractionAllowed(previousInteraction)
            throw ClaudeUsageFailure.permissionRequired
        }

        let result = Result { try operation() }
        // Metadata preflight and native reads share the same policy/lock scope.
        // Restore before returning either success or failure.
        guard client.setInteractionAllowed(previousInteraction) == errSecSuccess else {
            throw ClaudeUsageFailure.permissionRequired
        }
        return try result.get()
    }
}

// Never forward the bearer token to a redirect destination.
final class ClaudeUsageRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ClaudeUsageProbe {
    static let shared = ClaudeUsageProbe()
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession
    private let readCredential: @Sendable (Bool) async throws -> Data
    private let now: @Sendable () -> Date
    private var pending: [ClaudeUsageRequest: Task<ClaudeUsageResult, Never>] = [:]

    init(session: URLSession? = nil,
         readCredential: @escaping @Sendable (Bool) async throws -> Data = { try await ClaudeUsageCredentialReader.read(allowInteraction: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: config)
        }
        self.readCredential = readCredential
        self.now = now
    }

    func fetch(_ request: ClaudeUsageRequest) async -> ClaudeUsageResult {
        if let existing = pending[request] { return await existing.value }
        let task = Task { await query(request) }
        pending[request] = task
        let result = await task.value
        pending[request] = nil
        return result
    }

    private func query(_ request: ClaudeUsageRequest) async -> ClaudeUsageResult {
        var account: ClaudeUsageAccount?
        do {
            let credential = try ClaudeUsageParser.credential(await readCredential(request.allowKeychainPrompt), at: now())
            account = credential.account
            guard request.usage else { return .init(account: account) }
            var query = URLRequest(url: Self.endpoint)
            query.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            query.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            query.setValue("application/json", forHTTPHeaderField: "Accept")
            query.setValue("BoringNotch/ClaudeUsage", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: query, delegate: ClaudeUsageRedirectGuard())
            guard let http = response as? HTTPURLResponse else { throw ClaudeUsageFailure.invalidResponse }
            guard http.statusCode == 200 else {
                bytes.task.cancel()
                throw ClaudeUsageParser.issue(for: http.statusCode,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After"), at: now())
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < ClaudeUsageParser.maximumResponseBytes else {
                    bytes.task.cancel()
                    throw ClaudeUsageFailure.invalidResponse
                }
                data.append(byte)
            }
            let snapshot = try ClaudeUsageParser.snapshot(data, account: credential.account, at: now())
            return .init(account: account, snapshot: snapshot)
        } catch let error as URLError {
            return .init(account: account, issue: .init(failure: error.code == .timedOut ? .timedOut : .connection))
        } catch {
            // Neither the raw server body nor the credential is included in an error.
            return .init(account: account, issue: .from(error))
        }
    }
}
