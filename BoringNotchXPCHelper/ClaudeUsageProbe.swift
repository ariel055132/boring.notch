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
    private let renewCredential: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private var pending: [ClaudeUsageRequest: Task<ClaudeUsageResult, Never>] = [:]
    private var pendingRenewal: Task<Void, Error>?
    private var nextRenewalAt: Date = .distantPast

    init(session: URLSession? = nil,
         readCredential: @escaping @Sendable (Bool) async throws -> Data = { try await ClaudeUsageCredentialReader.read(allowInteraction: $0) },
         renewCredential: @escaping @Sendable () async throws -> Void = { try await ClaudeUsageRenewalProcess.renew() },
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
        self.renewCredential = renewCredential
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
            var credential = try ClaudeUsageParser.credential(await readCredential(request.allowKeychainPrompt),
                                                              at: now(), allowExpired: request.usage)
            account = credential.account
            guard request.usage else { return .init(account: account) }
            var renewed = false
            if credential.isExpired(at: now()) {
                credential = try await recover(credential)
                account = credential.account
                renewed = true
            }
            for _ in 0..<2 {
                do {
                    let snapshot = try await usage(credential)
                    return .init(account: account, snapshot: snapshot)
                } catch let issue as ClaudeUsageIssue where issue.failure == .expiredLogin {
                    guard !renewed else { throw ClaudeUsageFailure.renewalFailed }
                    credential = try await recover(credential)
                    account = credential.account
                    renewed = true
                }
            }
            throw ClaudeUsageFailure.renewalFailed
        } catch let error as URLError {
            return .init(account: account, issue: .init(failure: error.code == .timedOut ? .timedOut : .connection))
        } catch {
            // Neither the raw server body nor the credential is included in an error.
            return .init(account: account, issue: .from(error))
        }
    }

    private func recover(_ previous: ClaudeUsageCredential) async throws -> ClaudeUsageCredential {
        // Claude Code may already have rotated the token while our HTTP request
        // was in flight. Re-read before starting a second process.
        let current = try ClaudeUsageParser.credential(await readCredential(false), at: now(), allowExpired: true)
        if current.account != previous.account, !current.isExpired(at: now()) { return current }
        guard current.canRenew else { throw ClaudeUsageFailure.expiredLogin }
        if let pendingRenewal {
            try await pendingRenewal.value
        } else {
            guard now() >= nextRenewalAt else { throw ClaudeUsageFailure.renewalFailed }
            nextRenewalAt = now().addingTimeInterval(300)
            let task = Task { try await renewCredential() }
            pendingRenewal = task
            defer { pendingRenewal = nil }
            try await task.value
        }
        do {
            // An acknowledged CLI request is not proof of a renewed credential.
            return try ClaudeUsageParser.credential(await readCredential(false), at: now())
        } catch ClaudeUsageFailure.expiredLogin {
            throw ClaudeUsageFailure.renewalFailed
        }
    }

    private func usage(_ credential: ClaudeUsageCredential) async throws -> ClaudeUsageSnapshot {
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
        return try ClaudeUsageParser.snapshot(data, account: credential.account, at: now())
    }
}
