import Foundation
import Darwin

@main
struct CodexUsageProbeChecks {
    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            do {
                let result = try await CodexUsageProbe.shared.fetch(.init(quota: true, history: true))
                print("Live Codex usage: \(result.quota != nil ? "quota available" : "quota unavailable"); history \(result.history != nil ? "available" : "unavailable"); credentials were not printed.")
            } catch {
                print("Live Codex usage: \((error as? CodexUsageFailure ?? .connection).rawValue)")
                throw error
            }
            return
        }
        let fixture = CommandLine.arguments[1]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-probe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0
        func expect(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "CodexUsageProbeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        func process(_ mode: String, request: CodexUsageRequest = .init(quota: true), timeout: TimeInterval = 3) -> CodexUsageProcess {
            CodexUsageProcess(launch: CodexUsageLaunch(
                executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [fixture, mode, directory.appendingPathComponent(mode).path],
                environment: ["PATH": "/usr/bin:/bin"], workingDirectory: directory),
                request: request, timeout: timeout, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        }
        let result = try await process("success").fetch().quota!
        try expect(result.windows.count == 2, "Partial records and notifications must not lose quota windows")
        try expect(result.windows[0].remainingPercent == 75 && result.windows[1].remainingPercent == 40,
                   "Used percentage must be converted to remaining percentage")
        try expect(result.windows[0].durationMinutes == 300 && result.windows[1].durationLabel == "Weekly",
                   "Window lengths must come from the response")
        try expect(result.accountEmail == "fixture@example.invalid" && result.plan == "plus", "Account and plan must be retained")
        try expect(result.credits == 12.5, "Credits must be decoded without inventing a currency")
        try expect(result.fetchedAt == Date(timeIntervalSince1970: 1_800_000_000), "Timestamp must be the successful fetch time")
        let transcript = try String(contentsOf: directory.appendingPathComponent("success"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        try expect(transcript.compactMap { $0["method"] as? String } ==
                   ["initialize", "initialized", "account/read", "account/rateLimits/read"],
                   "The probe must only initialize and read account/usage, without inference or login")
        for (mode, expected) in [
            ("signed-out", CodexUsageFailure.notSignedIn), ("api-key", .apiKeyAccount),
            ("unsupported", .unsupportedCLI), ("unauthorized", .notSignedIn),
            ("rate-limited", .rateLimited), ("network", .connection), ("malformed", .invalidResponse),
            ("flood", .invalidResponse), ("exit", .connection), ("hang", .timedOut),
        ] {
            do {
                let result = try await process(mode, timeout: mode == "hang" ? 0.5 : 3).fetch()
                if let issue = result.quotaIssue { throw issue.failure }
                try expect(false, "\(mode) must fail")
            } catch let failure as CodexUsageFailure {
                try expect(failure == expected, "\(mode) returned \(failure) instead of \(expected)")
            }
        }
        try await Task.sleep(for: .seconds(1.2))
        let hungPID = Int32(try String(contentsOf: directory.appendingPathComponent("hang.pid"), encoding: .utf8))!
        try expect(kill(hungPID, 0) != 0, "A process ignoring SIGTERM must be killed after timeout")
        let cancelled = Task { try await process("hang", timeout: 10).fetch() }
        try await Task.sleep(for: .milliseconds(200))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            try expect(false, "Cancellation must end the probe")
        } catch is CancellationError {
            try expect(true, "Cancellation returned")
        }
        try await Task.sleep(for: .seconds(1.2))
        let cancelledPID = Int32(try String(contentsOf: directory.appendingPathComponent("hang.pid"), encoding: .utf8))!
        try expect(kill(cancelledPID, 0) != 0, "Cancellation must also reap an uncooperative child")

        let account = CodexUsageParser.Account(type: "chatgpt", email: nil, planType: "pro")
        func parse(_ text: String) throws -> CodexUsageSnapshot {
            try CodexUsageParser.snapshot(from: Data(text.utf8), account: account, at: Date())
        }
        let multiple = try parse(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"extra":{"limitName":"Extra model","primary":{"usedPercent":120,"windowDurationMins":60},"secondary":{"resetsAt":1900000000}},"codex":{"primary":{"usedPercent":0,"windowDurationMins":15},"secondary":{"usedPercent":35,"windowDurationMins":10080}}}}"#)
        try expect(multiple.windows.count == 4 && multiple.windows[0].remainingPercent == 100, "Multi-bucket data must take precedence over legacy data")
        try expect(multiple.windows[0].durationLabel == "15 minutes", "A short window must not be mislabeled five hours")
        try expect(multiple.windows[2].remainingPercent == 0 && multiple.windows[2].bucketName == "Extra model", "Over-limit values must clamp and extra buckets need labels")
        try expect(multiple.windows[3].remainingPercent == nil, "Missing usage is unknown, never 100% remaining")
        let reset = result.windows[0].resetsAt!
        try expect(result.windows[0].isCurrent(at: reset.addingTimeInterval(-1)), "Pre-reset data remains current")
        try expect(!result.windows[0].isCurrent(at: reset), "Past-reset data must not imply replenishment")
        let credits = try parse(#"{"rateLimits":{"credits":{"balance":"0","unlimited":false}}}"#)
        try expect(credits.credits == 0 && credits.windows.isEmpty, "A real zero credit balance is valid")
        let unlimited = try parse(#"{"rateLimits":{"credits":{"unlimited":true}}}"#)
        try expect(unlimited.unlimitedCredits, "Unlimited credit accounts do not require percentages")
        do {
            _ = try parse(#"{"rateLimits":{"primary":{"usedPercent":-1}}}"#)
            try expect(false, "Invalid data must not become a full allowance")
        } catch let failure as CodexUsageFailure {
            try expect(failure == .usageUnavailable, "Unavailable data needs an explicit state")
        }
        let complete = try await process("history", request: .init(quota: true, history: true)).fetch()
        try expect(complete.quota != nil && complete.history?.days.count == 3, "Quota and daily history must both be returned")
        try expect(complete.history?.days.first?.tokens == 0, "A reported zero must be retained")
        let onlyHistory = try await process("history-only", request: .init(history: true)).fetch()
        try expect(onlyHistory.quota == nil && onlyHistory.history != nil, "A history-only query must not fetch quota")
        let identity = try await process("identity", request: .init()).fetch()
        try expect(identity.account?.email == "fixture@example.invalid" && identity.quota == nil && identity.history == nil,
                   "Startup can verify identity without either remote statistics query")
        for mode in ["history-only", "identity"] {
            let transcript = try String(contentsOf: directory.appendingPathComponent(mode), encoding: .utf8)
            try expect(!transcript.contains("account/rateLimits/read"), "Independent gates must not trigger extra quota requests")
        }
        let limited = try await process("rate-limited", request: .init(quota: true, history: true)).fetch()
        try expect(limited.quotaIssue?.failure == .rateLimited && limited.history == nil,
                   "Quota 429 must stop the history query in the same process")
        let partial = try await process("history-failure", request: .init(quota: true, history: true)).fetch()
        try expect(partial.quota != nil && partial.historyIssue?.failure == .connection,
                   "History failure must not discard successful quota")
        let missing = try await process("history-null", request: .init(history: true)).fetch()
        try expect(missing.historyIssue?.failure == .historyUnavailable, "Null history means unavailable, not zero")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let hinted = CodexUsageParser.issue(for: ["code": 429, "data": ["retryAfterSeconds": 7200]], at: date)
        try expect(hinted.retryAt == date.addingTimeInterval(7200), "Server retry hints must survive parsing")
        let noHint = CodexUsageParser.issue(for: ["code": 429, "data": ["retryAfterSeconds": -5]], at: date)
        try expect(noHint.retryAt == nil, "Negative retry hints must not shorten backoff")
        for invalid in [#"{"dailyUsageBuckets":[{"startDate":"2026-02-30","tokens":1}]}"#,
                        #"{"dailyUsageBuckets":[{"startDate":"2026-10-02","tokens":-1}]}"#,
                        #"{"dailyUsageBuckets":[{"startDate":"2026-10-02","tokens":1},{"startDate":"2026-10-02","tokens":2}]}"#] {
            let parsed = try? CodexUsageParser.history(from: Data(invalid.utf8), at: date)
            try expect(parsed == nil, "Invalid daily buckets must be rejected")
        }
        print("Codex usage probe checks passed: \(checks)")
    }
}
