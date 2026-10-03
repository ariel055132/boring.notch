import Foundation

enum CodexUsageParser {
    struct AccountResult: Decodable {
        let account: Account?
    }

    struct Account: Decodable {
        let type: String
        let email: String?
        let planType: String?
    }

    private struct LimitsResult: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
    }

    private struct Bucket: Decodable {
        let limitId: String?
        let limitName: String?
        let planType: String?
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
    }

    private struct Window: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Int?
        let resetsAt: Double?
    }

    private struct Credits: Decodable {
        let unlimited: Bool?
        let balance: String?
    }

    private struct HistoryResult: Decodable {
        struct Day: Decodable {
            let startDate: String
            let tokens: Int64
        }
        let dailyUsageBuckets: [Day]?
    }

    static func history(from data: Data, at date: Date) throws -> CodexUsageHistory {
        let result = try JSONDecoder().decode(HistoryResult.self, from: data)
        guard let buckets = result.dailyUsageBuckets else { throw CodexUsageFailure.historyUnavailable }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        var days: [String: Int64] = [:]
        for bucket in buckets {
            guard bucket.tokens >= 0, let parsed = formatter.date(from: bucket.startDate),
                  formatter.string(from: parsed) == bucket.startDate,
                  days[bucket.startDate].map({ $0 == bucket.tokens }) ?? true else {
                throw CodexUsageFailure.invalidResponse
            }
            days[bucket.startDate] = bucket.tokens
        }
        return CodexUsageHistory(days: days.sorted { $0.key < $1.key }.map {
            CodexDailyTokens(date: $0.key, tokens: $0.value)
        }, fetchedAt: date)
    }

    static func issue(for error: [String: Any], at date: Date) -> CodexUsageIssue {
        let code = error["code"] as? Int
        let message = (error["message"] as? String ?? "").lowercased()
        let failure: CodexUsageFailure
        if code == -32601 { failure = .unsupportedCLI }
        else if code == 401 || message.contains("unauthorized") || message.contains("not logged")
            || message.contains("not authenticated") || message.contains("sign in") { failure = .notSignedIn }
        else if code == 429 || message.contains("429") || message.contains("too many requests") { failure = .rateLimited }
        else { failure = .connection }

        // App-server does not promise to expose HTTP headers. Honor a structured
        // Retry-After if forwarded; otherwise the app uses its own backoff.
        let data = error["data"] as? [String: Any]
        let headers = data?["headers"] as? [String: Any]
        let hint = data?["retryAfterSeconds"] ?? data?["retryAfter"]
            ?? headers?.first(where: { $0.key.lowercased() == "retry-after" })?.value
        var retryAt: Date?
        if failure == .rateLimited, let hint {
            let seconds = (hint as? NSNumber)?.doubleValue ?? (hint as? String).flatMap(Double.init)
            if let seconds, seconds.isFinite, seconds >= 0 {
                let candidate = date.addingTimeInterval(seconds)
                if candidate.timeIntervalSinceReferenceDate.isFinite { retryAt = candidate }
            } else if let text = hint as? String {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                retryAt = formatter.date(from: text).flatMap { $0 > date ? $0 : nil }
            }
        }
        return CodexUsageIssue(failure: failure, retryAt: retryAt)
    }

    static func snapshot(from data: Data, account: Account, at date: Date) throws -> CodexUsageSnapshot {
        let result = try JSONDecoder().decode(LimitsResult.self, from: data)
        let buckets: [(String, Bucket)]
        if let multiple = result.rateLimitsByLimitId, !multiple.isEmpty {
            buckets = multiple.sorted {
                if $0.key == "codex" { return $1.key != "codex" }
                if $1.key == "codex" { return false }
                return $0.key < $1.key
            }
        } else if let bucket = result.rateLimits {
            buckets = [(bucket.limitId ?? "codex", bucket)]
        } else {
            throw CodexUsageFailure.usageUnavailable
        }
        let windows = buckets.flatMap { id, bucket in
            [(true, bucket.primary), (false, bucket.secondary)].compactMap { primary, raw -> CodexUsageWindow? in
                guard let raw else { return nil }
                let used = raw.usedPercent.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                let reset = raw.resetsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                return CodexUsageWindow(
                    id: "\(id)/\(primary ? "primary" : "secondary")",
                    bucketName: id == "codex" ? nil : (bucket.limitName ?? id),
                    usedPercent: used,
                    durationMinutes: raw.windowDurationMins.flatMap { $0 > 0 ? $0 : nil },
                    resetsAt: reset,
                    isPrimary: primary)
            }
        }
        let main = buckets.first(where: { $0.0 == "codex" })?.1 ?? result.rateLimits ?? buckets.first?.1
        let credits = main?.credits?.balance.flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let unlimited = main?.credits?.unlimited == true
        guard windows.contains(where: { $0.usedPercent != nil }) || credits != nil || unlimited else {
            throw CodexUsageFailure.usageUnavailable
        }
        return CodexUsageSnapshot(accountEmail: account.email, plan: main?.planType ?? account.planType,
                                  windows: windows, credits: credits, unlimitedCredits: unlimited, fetchedAt: date)
    }
}
