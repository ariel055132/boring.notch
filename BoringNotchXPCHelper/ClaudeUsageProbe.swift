import Foundation
import LocalAuthentication
import Security

enum ClaudeUsageKeychain {
    static func read(allowInteraction: Bool) throws -> Data {
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
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw ClaudeUsageFailure.notSignedIn }
            return data
        case errSecItemNotFound: throw ClaudeUsageFailure.notSignedIn
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw ClaudeUsageFailure.permissionRequired
        default: throw ClaudeUsageFailure.connection
        }
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
    private let readCredential: @Sendable (Bool) throws -> Data
    private let now: @Sendable () -> Date
    private var pending: [ClaudeUsageRequest: Task<ClaudeUsageResult, Never>] = [:]

    init(session: URLSession? = nil,
         readCredential: @escaping @Sendable (Bool) throws -> Data = { try ClaudeUsageKeychain.read(allowInteraction: $0) },
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
            let credential = try ClaudeUsageParser.credential(readCredential(request.allowKeychainPrompt), at: now())
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
