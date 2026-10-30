import Darwin
import Foundation
import os

// Only injected fake readers and the Python fixture execute. No system security
// command, real credential, Keychain API, or network endpoint is accessed.
@main
@MainActor
private struct ClaudeUsageSecurityCommandChecks {
    static var checks = 0
    static let payload = Data("fixture-credential".utf8)

    static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "ClaudeSecurityCommandChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        checks += 1
    }

    static func failure(_ expected: ClaudeUsageFailure,
                        _ operation: () async throws -> Data) async throws {
        do {
            _ = try await operation()
            try expect(false, "Expected sanitized command failure")
        } catch let actual as ClaudeUsageFailure {
            try expect(actual == expected, "Command must map its failure correctly")
            let description = String(describing: actual) + actual.localizedDescription
            try expect(!description.contains("fixture-credential") && !description.contains("fixture-private-stderr"),
                       "Failed reads must not expose stdout or stderr")
        }
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "ClaudeSecurityCommandChecks", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Pass Python executable and fixture path"])
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-command-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await processChecks(directory: directory)
        try await readerChecks()
        print("Claude usage security command/reader checks passed: \(checks)")
    }

    static func command(_ mode: String, directory: URL, timeout: TimeInterval = 2,
                        maximumBytes: Int = 1024) -> (ClaudeUsageSecurityCommand, URL) {
        let report = directory.appendingPathComponent(UUID().uuidString + ".pid")
        return (ClaudeUsageSecurityCommand(executable: URL(fileURLWithPath: CommandLine.arguments[1]),
                    arguments: [CommandLine.arguments[2], mode, report.path], timeout: timeout,
                    maximumBytes: maximumBytes), report)
    }

    static func processChecks(directory: URL) async throws {
        for (mode, expected) in [("success", payload), ("no-newline", payload),
                                 ("two-newlines", payload + Data([10]))] {
            let (reader, _) = command(mode, directory: directory)
            let result = try await reader.read()
            try expect(result == expected, "Successful reads must preserve bytes and remove only the CLI newline")
        }
        let (boundary, _) = command("boundary", directory: directory, maximumBytes: 65)
        let boundaryData = try await boundary.read()
        try expect(boundaryData == Data(repeating: 120, count: 64), "The exact output bound includes the CLI newline")

        for (mode, expected) in [("empty", ClaudeUsageFailure.notSignedIn), ("newline", .notSignedIn),
                                 ("failure", .permissionRequired), ("missing", .notSignedIn),
                                 ("eof-before-failure", .permissionRequired)] {
            let (reader, _) = command(mode, directory: directory)
            try await failure(expected) { try await reader.read() }
        }
        let (oversized, oversizedPID) = command("flood", directory: directory, maximumBytes: 64)
        try await failure(.invalidResponse) { try await oversized.read() }
        try await assertExited(report: oversizedPID)

        let (environment, _) = command("environment", directory: directory)
        let environmentData = try await environment.read()
        let state = try JSONSerialization.jsonObject(with: environmentData) as? [String: Any]
        try expect(state?["cwd"] as? String == "/" && state?["stdinBytes"] as? Int == 0,
                   "Commands must not inherit an interactive stdin or project working directory")
        try expect(state?["path"] as? String == "/usr/bin:/bin:/usr/sbin:/sbin"
                   && state?["lang"] as? String == "C" && state?["homePresent"] as? Bool == true,
                   "Commands must use the fixed environment needed by the system tool")

        let missing = ClaudeUsageSecurityCommand(executable: directory.appendingPathComponent("absent-executable"),
                                                 arguments: [], timeout: 0.3)
        try await failure(.connection) { try await missing.read() }
        for mode in ["hang", "resist-term"] {
            let (reader, report) = command(mode, directory: directory, timeout: 0.4)
            let start = Date()
            try await failure(.timedOut) { try await reader.read() }
            try expect(Date().timeIntervalSince(start) < 2, "Timeout must return without waiting indefinitely for the child")
            try await assertExited(report: report)
        }

        let (cancelReader, report) = command("resist-term", directory: directory, timeout: 10)
        let task = Task { try await cancelReader.read() }
        try await waitForReport(report)
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            try expect(false, "Cancelled read must not return a partial credential")
        } catch is CancellationError {
            try expect(Date().timeIntervalSince(cancelledAt) < 1, "Cancellation must resume promptly")
        }
        try await assertExited(report: report)

        let (earlyReader, earlyReport) = command("hang", directory: directory, timeout: 10)
        let early = Task { try await earlyReader.read() }
        early.cancel()
        do {
            _ = try await early.value
            try expect(false, "Cancellation before startup must not return data")
        } catch is CancellationError {
            try expect(true, "Cancellation before startup is handled")
        }
        if FileManager.default.fileExists(atPath: earlyReport.path) { try await assertExited(report: earlyReport) }
    }

    static func waitForReport(_ report: URL) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let text = try? String(contentsOf: report, encoding: .utf8), Int32(text) != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(false, "Fixture must report its PID before cancellation")
    }

    static func assertExited(report: URL) async throws {
        try await waitForReport(report)
        let pid = Int32(try String(contentsOf: report, encoding: .utf8))!
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH {
                try expect(true, "Fixture child has been reaped")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = kill(pid, SIGKILL) // Clean up only this known offline fixture on test failure.
        try expect(false, "Timeout/cancellation must kill even a TERM-resistant fixture within a bounded interval")
    }

    struct Calls: Sendable {
        var preflight = 0
        var command = 0
        var target: ClaudeUsageSecurityTarget?
        var interaction: Bool?
    }

    static func readerChecks() async throws {
        // This must reject before constructing or launching /usr/bin/security.
        try await failure(.permissionRequired) {
            try await ClaudeUsageSecurityCommand.read(target: nil, allowInteraction: false)
        }
        let target = ClaudeUsageSecurityTarget(account: "fixture-account", keychainPath: "/fixture/login.keychain-db")
        let calls = OSAllocatedUnfairLock(initialState: Calls())
        let data = payload
        let native = try await ClaudeUsageCredentialReader.read(allowInteraction: false,
            nativeRead: { data }, preflight: {
                calls.withLock { $0.preflight += 1 }; return target
            }, command: { _, _ in calls.withLock { $0.command += 1 }; return data })
        try expect(native == data && calls.withLock { $0.preflight == 0 && $0.command == 0 },
                   "Native success must never invoke the system-tool fallback")

        for interactive in [false, true] {
            calls.withLock { $0 = Calls() }
            let result = try await ClaudeUsageCredentialReader.read(allowInteraction: interactive,
                nativeRead: { throw ClaudeUsageFailure.permissionRequired }, preflight: {
                    calls.withLock { $0.preflight += 1 }; return target
                }, command: { received, allowed in
                    calls.withLock { $0.command += 1; $0.target = received; $0.interaction = allowed }; return data
                })
            try expect(result == data && calls.withLock {
                $0.preflight == 1 && $0.command == 1 && $0.target == target && $0.interaction == interactive
            }, "Fallback must preserve the exact preflight target and caller interaction policy")
        }

        calls.withLock { $0 = Calls() }
        try await failure(.permissionRequired) {
            try await ClaudeUsageCredentialReader.read(allowInteraction: false,
                nativeRead: { throw ClaudeUsageFailure.permissionRequired },
                preflight: { throw ClaudeUsageFailure.permissionRequired },
                command: { _, _ in calls.withLock { $0.command += 1 }; return data })
        }
        try expect(calls.withLock { $0.command == 0 }, "Rejected background preflight must never launch a command")

        let connected = try await ClaudeUsageCredentialReader.read(allowInteraction: true,
            nativeRead: { throw ClaudeUsageFailure.permissionRequired },
            preflight: { throw ClaudeUsageFailure.permissionRequired },
            command: { received, allowed in
                calls.withLock { $0.command += 1; $0.target = received; $0.interaction = allowed }; return data
            })
        try expect(connected == data && calls.withLock { $0.command == 1 && $0.target == nil && $0.interaction == true },
                   "Explicit Connect may request command authorization when preflight rejects existing access")

        for nativeFailure in [ClaudeUsageFailure.notSignedIn, .connection, .expiredLogin] {
            calls.withLock { $0 = Calls() }
            try await failure(nativeFailure) {
                try await ClaudeUsageCredentialReader.read(allowInteraction: true,
                    nativeRead: { throw nativeFailure }, preflight: {
                        calls.withLock { $0.preflight += 1 }; return target
                    }, command: { _, _ in calls.withLock { $0.command += 1 }; return data })
            }
            try expect(calls.withLock { $0.preflight == 0 && $0.command == 0 },
                       "Missing credentials and non-permission failures must not start a fallback")
        }
        for interactive in [false, true] {
            calls.withLock { $0 = Calls() }
            try await failure(.notSignedIn) {
                try await ClaudeUsageCredentialReader.read(allowInteraction: interactive,
                    nativeRead: { throw ClaudeUsageFailure.permissionRequired }, preflight: {
                        calls.withLock { $0.preflight += 1 }; throw ClaudeUsageFailure.notSignedIn
                    }, command: { _, _ in calls.withLock { $0.command += 1 }; return data })
            }
            try expect(calls.withLock { $0.preflight == 1 && $0.command == 0 },
                       "A credential disappearing during preflight must never launch a command, even for Connect")
        }
        try await failure(.notSignedIn) {
            try await ClaudeUsageCredentialReader.read(allowInteraction: false,
                nativeRead: { throw ClaudeUsageFailure.permissionRequired }, preflight: { target },
                command: { _, _ in throw ClaudeUsageFailure.notSignedIn })
        }
    }
}
