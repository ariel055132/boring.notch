import CryptoKit
import Foundation

// Credentials live only inside the unsandboxed helper. Do not make this type
// Codable, include it in errors, or send it through the XPC protocol.
struct ClaudeUsageCredential: Sendable {
    let accessToken: String
    let account: ClaudeUsageAccount
}

enum ClaudeUsageParser {
    static let maximumResponseBytes = 1_048_576
    static let windowKeys = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus",
                             "seven_day_oauth_apps", "seven_day_cowork"]

    private struct CredentialEnvelope: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
            let subscriptionType: String?
            let scopes: [String]?
        }
        let claudeAiOauth: OAuth?
    }

    static func credential(_ data: Data, at date: Date) throws -> ClaudeUsageCredential {
        guard data.count <= maximumResponseBytes,
              let envelope = try? JSONDecoder().decode(CredentialEnvelope.self, from: data),
              let oauth = envelope.claudeAiOauth,
              !oauth.accessToken.isEmpty,
              !oauth.accessToken.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ClaudeUsageFailure.notSignedIn
        }
        if let expiresAt = oauth.expiresAt {
            guard expiresAt.isFinite, expiresAt / 1000 > date.timeIntervalSince1970 else {
                throw ClaudeUsageFailure.expiredLogin
            }
        }
        if let scopes = oauth.scopes, !scopes.contains("user:profile") {
            throw ClaudeUsageFailure.unsupportedAccount
        }
        let fingerprint = SHA256.hash(data: Data(oauth.accessToken.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return .init(accessToken: oauth.accessToken,
                     account: .init(credentialID: fingerprint, plan: oauth.subscriptionType))
    }

    private struct WindowPayload: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    static func snapshot(_ data: Data, account: ClaudeUsageAccount, at date: Date) throws -> ClaudeUsageSnapshot {
        guard data.count <= maximumResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeUsageFailure.invalidResponse
        }
        var windows: [ClaudeUsageWindow] = []
        for key in windowKeys {
            guard let value = object[key], !(value is NSNull) else { continue }
            guard let dictionary = value as? [String: Any],
                  let encoded = try? JSONSerialization.data(withJSONObject: dictionary),
                  let payload = try? JSONDecoder().decode(WindowPayload.self, from: encoded),
                  payload.utilization.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw ClaudeUsageFailure.invalidResponse
            }
            let reset: Date?
            if let value = payload.resets_at {
                guard let parsed = iso8601(value) else { throw ClaudeUsageFailure.invalidResponse }
                reset = parsed
            } else { reset = nil }
            windows.append(.init(id: key, usedPercent: payload.utilization, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw ClaudeUsageFailure.usageUnavailable }
        return .init(account: account, windows: windows, fetchedAt: date)
    }

    private static func iso8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func retryDate(_ value: String?, at date: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return date.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).flatMap { $0 > date ? $0 : nil }
    }

    static func issue(for status: Int, retryAfter: String?, at date: Date) -> ClaudeUsageIssue {
        switch status {
        case 401: .init(failure: .expiredLogin)
        case 403: .init(failure: .unsupportedAccount)
        case 429: .init(failure: .rateLimited, retryAt: retryDate(retryAfter, at: date))
        case 500...599: .init(failure: .connection)
        default: .init(failure: .invalidResponse)
        }
    }
}
