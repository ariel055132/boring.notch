import Foundation

struct ClaudeUsageRequest: Codable, Hashable, Sendable {
    var usage = false
    // Only explicit Connect may request new Keychain authorization. Background
    // CLI fallback requires existing access; its preflight is not atomic with a
    // subsequent external Keychain lock or ACL change.
    var allowKeychainPrompt = false
}

struct ClaudeUsageAccount: Codable, Equatable, Sendable {
    // Opaque fingerprint, never the OAuth token. A refreshed credential also
    // invalidates old cached data rather than risking a different account's data.
    let credentialID: String
    let plan: String?
}

struct ClaudeUsageResult: Codable, Sendable {
    var account: ClaudeUsageAccount?
    var snapshot: ClaudeUsageSnapshot?
    var issue: ClaudeUsageIssue?
}

struct ClaudeUsageIssue: Codable, Error, Sendable {
    let failure: ClaudeUsageFailure
    var retryAt: Date?

    static func from(_ error: Error) -> Self {
        error as? Self ?? Self(failure: error as? ClaudeUsageFailure ?? .connection)
    }
}

// Only these sanitized values cross XPC or are persisted by the app.
struct ClaudeUsageSnapshot: Codable, Sendable {
    let account: ClaudeUsageAccount
    let windows: [ClaudeUsageWindow]
    let fetchedAt: Date
}

struct ClaudeUsageWindow: Codable, Identifiable, Sendable {
    let id: String
    let usedPercent: Double?
    let resetsAt: Date?

    var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite, usedPercent >= 0 else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    func isCurrent(at date: Date) -> Bool { resetsAt.map { date < $0 } ?? true }

    var title: String {
        switch id {
        case "five_hour": String(localized: "5 hours")
        case "seven_day": String(localized: "Weekly · All models")
        case "seven_day_sonnet": String(localized: "Weekly · Sonnet")
        case "seven_day_opus": String(localized: "Weekly · Opus")
        case "seven_day_oauth_apps": String(localized: "Weekly · OAuth apps")
        case "seven_day_cowork": String(localized: "Weekly · Cowork")
        default: String(localized: "Usage limit")
        }
    }
}

enum ClaudeUsageFailure: String, Codable, Error, Sendable, LocalizedError {
    case notSignedIn, permissionRequired, expiredLogin, unsupportedAccount
    case timedOut, connection, invalidResponse, usageUnavailable, rateLimited, dataExpired

    var needsConnection: Bool {
        switch self {
        case .notSignedIn, .permissionRequired, .expiredLogin, .unsupportedAccount: true
        default: false
        }
    }

    var invalidatesSnapshot: Bool { needsConnection || self == .usageUnavailable }

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            String(localized: "Sign in to Claude Code with your Claude subscription, then connect.")
        case .permissionRequired:
            String(localized: "Unlock your login keychain, or connect to allow Claude usage access through the macOS security tool.")
        case .expiredLogin:
            String(localized: "Your Claude Code sign-in has expired. Run /usage in Claude Code, then click Retry connection.")
        case .unsupportedAccount:
            String(localized: "Sign in to Claude Code with a Claude subscription to see your plan's usage.")
        case .timedOut:
            String(localized: "Claude took too long to respond. Updates will retry automatically.")
        case .connection:
            String(localized: "Could not retrieve Claude usage. Updates will retry automatically.")
        case .invalidResponse:
            String(localized: "Claude returned an unreadable usage response.")
        case .usageUnavailable:
            String(localized: "Claude has no usage limits available for this account.")
        case .rateLimited:
            String(localized: "Claude is limiting usage checks. The next update will wait longer.")
        case .dataExpired:
            String(localized: "The last usage data is out of date. Waiting for a successful update.")
        }
    }
}
