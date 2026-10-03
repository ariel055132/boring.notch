import Foundation

struct CodexUsageRequest: Codable, Hashable, Sendable {
    var quota = false
    var history = false
}

struct CodexUsageAccount: Codable, Equatable, Sendable {
    let email: String?
    let plan: String?

    // account/read exposes email and plan, not credentials. Accounts without an
    // email are usable for this session, but cannot safely restore a disk cache.
    var cacheKey: String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else { return nil }
        return "\(email.lowercased())|\(plan ?? "")"
    }
}

struct CodexUsageResult: Codable, Sendable {
    var account: CodexUsageAccount?
    var quota: CodexUsageSnapshot?
    var history: CodexUsageHistory?
    var quotaIssue: CodexUsageIssue?
    var historyIssue: CodexUsageIssue?
    var issue: CodexUsageIssue?
}

struct CodexUsageIssue: Codable, Error, Sendable {
    let failure: CodexUsageFailure
    var retryAt: Date?

    static func from(_ error: Error) -> Self {
        error as? Self ?? Self(failure: error as? CodexUsageFailure ?? .connection)
    }
}

struct CodexDailyTokens: Codable, Equatable, Sendable {
    let date: String
    let tokens: Int64
}

struct CodexUsageDay: Identifiable, Sendable {
    let id: String
    let date: Date
    let tokens: Int64?
}

struct CodexUsageHistory: Codable, Sendable {
    let days: [CodexDailyTokens]
    let fetchedAt: Date

    var latestReportedDate: String? { days.map(\.date).max() }

    // Keep the service's date-only labels intact. Do not claim the service uses
    // the Mac's timezone or turn missing buckets into zero-use days.
    func recentDays(at date: Date, timeZone: TimeZone = .current) -> [CodexUsageDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: date)
        let byDate = Dictionary(days.map { ($0.date, $0.tokens) }, uniquingKeysWith: { first, _ in first })
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            return CodexUsageDay(id: key, date: day, tokens: byDate[key])
        }
    }

    static func reportedTotal(_ days: [CodexUsageDay]) -> Int64? {
        guard days.contains(where: { $0.tokens != nil }) else { return nil }
        var total: Int64 = 0
        for tokens in days.compactMap(\.tokens) {
            let sum = total.addingReportingOverflow(tokens)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}

// Shared by the app and its XPC helper. No credentials cross the XPC boundary.
struct CodexUsageSnapshot: Codable, Sendable {
    let accountEmail: String?
    let plan: String?
    let windows: [CodexUsageWindow]
    let credits: Double?
    let unlimitedCredits: Bool
    let fetchedAt: Date
}

struct CodexUsageWindow: Codable, Identifiable, Sendable {
    let id: String
    let bucketName: String?
    let usedPercent: Double?
    let durationMinutes: Int?
    let resetsAt: Date?
    let isPrimary: Bool

    var remainingPercent: Double? {
        usedPercent.map { max(0, min(100, 100 - $0)) }
    }

    // A reset passing does not prove that the server has replenished the allowance.
    func isCurrent(at date: Date) -> Bool {
        resetsAt.map { date < $0 } ?? true
    }

    var durationLabel: String {
        guard let durationMinutes else {
            return isPrimary ? String(localized: "Primary limit") : String(localized: "Secondary limit")
        }
        if durationMinutes == 10_080 { return String(localized: "Weekly") }
        if durationMinutes == 1_440 { return String(localized: "Daily") }
        if durationMinutes % 60 == 0 { return String(localized: "\(durationMinutes / 60) hours") }
        return String(localized: "\(durationMinutes) minutes")
    }
}

enum CodexUsageFailure: String, Codable, Error, Sendable, LocalizedError {
    case cliNotFound, notSignedIn, apiKeyAccount, unsupportedCLI
    case timedOut, connection, invalidResponse, usageUnavailable, historyUnavailable, rateLimited, dataExpired

    var invalidatesSnapshot: Bool {
        switch self {
        case .notSignedIn, .apiKeyAccount, .cliNotFound, .unsupportedCLI, .usageUnavailable: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            String(localized: "Codex could not be found. Open your Codex app or install the official Codex CLI, then refresh.")
        case .notSignedIn:
            String(localized: "Sign in to Codex with your ChatGPT account, then refresh.")
        case .apiKeyAccount:
            String(localized: "Codex is using an API key. Sign in with ChatGPT to see your plan's remaining usage.")
        case .unsupportedCLI:
            String(localized: "Update Codex to a version that supports usage queries, then refresh.")
        case .timedOut:
            String(localized: "Codex took too long to respond. Updates will retry automatically.")
        case .connection:
            String(localized: "Could not retrieve Codex usage. Updates will retry automatically.")
        case .invalidResponse:
            String(localized: "Codex returned an unreadable usage response.")
        case .usageUnavailable:
            String(localized: "Codex has no usage limits available for this account.")
        case .historyUnavailable:
            String(localized: "Codex has not reported daily token usage for this account yet.")
        case .rateLimited:
            String(localized: "Codex is limiting usage checks. The next update will wait longer.")
        case .dataExpired:
            String(localized: "The last usage data is out of date. Waiting for a successful update.")
        }
    }
}
