import Darwin
import Foundation

@main
@MainActor
private struct ClaudeUsageRenewalChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "ClaudeRenewalChecks", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Pass Python and fixture path") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-renewal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try discovery()
        for mode in ["success", "split", "notifications"] {
            let (process, report) = fixture(mode, directory)
            try await process.run()
            try await exited(report)
            let lines = try String(contentsOf: report.appendingPathExtension("requests"), encoding: .utf8).split(separator: "\n")
            let requests = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            try expect(requests.count == 2 && requests.allSatisfy { $0["type"] as? String == "control_request" },
                       "Renewal must send exactly two control requests and no model prompt")
            let second = requests[1]["request"] as! [String: Any]
            try expect(second["subtype"] as? String == "get_usage" && second["skip_behaviors"] as? Bool == true,
                       "Usage query must skip scanning conversation histories")
        }
        let failures: [(String, ClaudeUsageFailure)] = [
            ("init-error", .renewalUnavailable), ("unsupported", .renewalUnavailable),
            ("interactive", .renewalUnavailable), ("assistant", .renewalUnavailable),
            ("nonzero", .renewalFailed), ("eof", .renewalFailed),
            ("malformed", .invalidResponse), ("flood", .invalidResponse),
            ("cost", .invalidResponse), ("api-duration", .invalidResponse), ("model", .invalidResponse),
            ("bool-zero", .invalidResponse), ("behaviors", .invalidResponse), ("missing-session", .invalidResponse),
            ("wrong-id", .timedOut), ("hang", .timedOut), ("resist-term", .timedOut)
        ]
        for (mode, expected) in failures {
            let (process, report) = fixture(mode, directory, timeout: 0.5)
            do { try await process.run(); try expect(false, "Expected \(mode) to fail") }
            catch let failure as ClaudeUsageFailure {
                try expect(failure == expected, "\(mode): expected \(expected), got \(failure)")
                try expect(!failure.localizedDescription.contains("fixture-private-token"), "Errors must not expose CLI output")
            }
            try await exited(report)
        }
        let (process, report) = fixture("resist-term", directory)
        let task = Task { try await process.run() }
        let startedDeadline = Date().addingTimeInterval(3)
        while (try? String(contentsOf: report, encoding: .utf8)).flatMap(Int32.init) == nil {
            guard Date() < startedDeadline else { throw NSError(domain: "ClaudeRenewalFixtureStartup", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { try await task.value; try expect(false, "Cancellation must fail") }
        catch is CancellationError { checks += 1 }
        try await exited(report)
        let (early, _) = fixture("hang", directory)
        let cancelled = Task { try await early.run() }
        cancelled.cancel()
        do { try await cancelled.value; try expect(false, "Early cancellation must fail") }
        catch is CancellationError { checks += 1 }
        print("Claude usage renewal protocol/process checks passed: \(checks)")
    }

    static func discovery() throws {
        let home = URL(fileURLWithPath: "/fixture")
        let launch = try ClaudeUsageRenewalLaunch.discover(environment: [
            "PATH": "relative:/fixture/bin", "CLAUDE_CONFIG_DIR": "/another-account", "ANTHROPIC_API_KEY": "fixture-secret",
            "NODE_OPTIONS": "--require=fixture", "BUN_OPTIONS": "fixture", "CLAUDE_CODE_OAUTH_TOKEN": "fixture-secret"
        ], home: home, isExecutable: { $0 == "/fixture/bin/claude" })
        try expect(launch.executable.path == "/fixture/bin/claude", "Discover an absolute CLI path")
        try expect(launch.environment["HOME"] == home.path && launch.environment["CLAUDE_CONFIG_DIR"] == nil,
                   "CLI must use the real user's default account, matching the Keychain reader")
        try expect(!launch.environment.values.contains { $0.contains("fixture-secret") || $0.contains("another-account") },
                   "Do not inherit credentials or a different account")
        try expect(launch.environment["NODE_OPTIONS"] == nil && launch.environment["BUN_OPTIONS"] == nil,
                   "Do not inherit code injection options")
        try expect(launch.workingDirectory.path == "/" && launch.arguments.contains("--safe-mode")
                   && launch.arguments.contains("--no-session-persistence") && launch.arguments.contains("--strict-mcp-config"),
                   "Renewal must disable customizations and session persistence outside the project")
        try expect(!launch.arguments.contains("/usage") && !launch.arguments.contains("login"),
                   "No slash command, prompt or login command may be passed")
        do {
            _ = try ClaudeUsageRenewalLaunch.discover(environment: [:], home: home, isExecutable: { _ in false })
            try expect(false, "Missing CLI must fail")
        } catch ClaudeUsageFailure.renewalUnavailable { checks += 1 }
    }

    static func fixture(_ mode: String, _ directory: URL, timeout: TimeInterval = 4) -> (ClaudeUsageRenewalProcess, URL) {
        let report = directory.appendingPathComponent(UUID().uuidString)
        let launch = ClaudeUsageRenewalLaunch(executable: URL(fileURLWithPath: CommandLine.arguments[1]),
            arguments: [CommandLine.arguments[2], mode, report.path], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: directory)
        return (ClaudeUsageRenewalProcess(launch: launch, timeout: timeout, maximumBytes: 4096), report)
    }

    static func exited(_ report: URL) async throws {
        let pid = Int32(try String(contentsOf: report, encoding: .utf8))!
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try expect(kill(pid, 0) != 0 && errno == ESRCH, "CLI must be terminated and reaped, including when it ignores TERM")
    }
}
