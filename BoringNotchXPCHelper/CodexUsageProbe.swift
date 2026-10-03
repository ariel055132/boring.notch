import Foundation
import Darwin

actor CodexUsageProbe {
    static let shared = CodexUsageProbe()
    private var pending: [CodexUsageRequest: Task<CodexUsageResult, Error>] = [:]

    func fetch(_ request: CodexUsageRequest) async throws -> CodexUsageResult {
        if let pending = pending[request] { return try await pending.value }
        let task = Task {
            let launch = try CodexUsageLaunch.discover()
            return try await CodexUsageProcess(launch: launch, request: request).fetch()
        }
        pending[request] = task
        defer { pending[request] = nil }
        return try await task.value
    }
}

struct CodexUsageLaunch: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL

    static func discover(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let home = URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory())
        let standardDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { $0.hasPrefix("/") }
        var directories: [String] = []
        for directory in pathDirectories + standardDirectories {
            if !directories.contains(directory) { directories.append(directory) }
        }
        var candidates = directories.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
        candidates += [".local/bin/codex", ".npm-global/bin/codex"].map { home.appendingPathComponent($0) }
        for apps in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            for app in ["ChatGPT.app", "Codex.app"] {
                for binary in ["codex-cli/CodexCLI.app/Contents/MacOS/codex", "codex-cli/bin/codex", "codex"] {
                    candidates.append(apps.appendingPathComponent("\(app)/Contents/Resources/\(binary)"))
                }
            }
        }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CodexUsageFailure.cliNotFound
        }
        var childEnvironment = environment
        childEnvironment["PATH"] = directories.joined(separator: ":")
        // No shell, prompt, thread, inference, or login command is exposed by this helper.
        return Self(executable: executable,
                    arguments: ["-s", "read-only", "-a", "never", "app-server", "--listen", "stdio://"],
                    environment: childEnvironment, workingDirectory: home)
    }
}

// Process, descriptors, parser state, and the continuation are confined to queue.
// The only cross-thread entry points enqueue work, including cancellation.
final class CodexUsageProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "theboringteam.boringnotch.codex-usage", qos: .utility)
    private let launch: CodexUsageLaunch
    private let request: CodexUsageRequest
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<CodexUsageResult, Error>?
    private var finished = false
    private var buffer = Data()
    private var bytesRead = 0
    private var expectedID = 0
    private var account: CodexUsageParser.Account?
    private var result = CodexUsageResult()

    init(launch: CodexUsageLaunch, request: CodexUsageRequest = .init(quota: true),
         timeout: TimeInterval = 20, now: @escaping @Sendable () -> Date = { Date() }) {
        self.launch = launch
        self.request = request
        self.timeout = timeout
        self.now = now
    }

    func fetch() async throws -> CodexUsageResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ continuation: CheckedContinuation<CodexUsageResult, Error>) {
        guard !finished else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = launch.executable
        child.arguments = launch.arguments
        child.environment = launch.environment
        child.currentDirectoryURL = launch.workingDirectory
        child.standardInput = stdin
        child.standardOutput = stdout
        // Never forward Codex logs, tokens, or raw backend errors to the app or console.
        child.standardError = FileHandle.nullDevice
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        do {
            try child.run()
        } catch {
            finish(.failure(CodexUsageFailure.connection))
            return
        }
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let descriptor = stdout.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drainOutput() }
        let readHandle = stdout.fileHandleForReading
        source.setCancelHandler { try? readHandle.close() }
        reader = source
        source.resume()
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { [weak self] in self?.finish(.failure(CodexUsageFailure.timedOut)) }
        timer = deadline
        deadline.resume()
        send(["id": 0, "method": "initialize",
              "params": ["clientInfo": ["name": "boring_notch_usage", "version": "1.0"]]])
    }

    private func drainOutput() {
        guard !finished, let output else { return }
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !finished {
            let count = Darwin.read(output.fileDescriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN { finish(.failure(CodexUsageFailure.connection)) }
                return
            }
            guard count > 0 else {
                finish(.failure(CodexUsageFailure.connection))
                return
            }
            bytesRead += count
            guard bytesRead <= 1_048_576 else {
                finish(.failure(CodexUsageFailure.invalidResponse))
                return
            }
            buffer.append(contentsOf: chunk.prefix(count))
            while !finished, let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { receive(line) }
            }
        }
    }

    private func receive(_ line: Data) {
        do {
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CodexUsageFailure.invalidResponse
            }
            // Notifications can be interleaved with replies. This client never starts a turn.
            guard let id = message["id"] as? Int, id == expectedID else { return }
            if let error = message["error"] as? [String: Any] {
                let issue = CodexUsageParser.issue(for: error, at: now())
                if id == 2 {
                    result.quotaIssue = issue
                    if issue.failure == .rateLimited || issue.failure == .notSignedIn {
                        finish(.success(result))
                    } else { readHistoryOrFinish() }
                } else if id == 3 {
                    result.historyIssue = issue
                    finish(.success(result))
                } else { finish(.failure(issue)) }
                return
            }
            guard let result = message["result"], JSONSerialization.isValidJSONObject(result) else {
                throw CodexUsageFailure.invalidResponse
            }
            let data = try JSONSerialization.data(withJSONObject: result)
            switch id {
            case 0:
                send(["method": "initialized"])
                expectedID = 1
                send(["id": 1, "method": "account/read", "params": ["refreshToken": false]])
            case 1:
                let response = try JSONDecoder().decode(CodexUsageParser.AccountResult.self, from: data)
                guard let account = response.account else { throw CodexUsageFailure.notSignedIn }
                guard account.type == "chatgpt" else {
                    throw account.type == "apiKey" ? CodexUsageFailure.apiKeyAccount : CodexUsageFailure.usageUnavailable
                }
                self.account = account
                self.result.account = CodexUsageAccount(email: account.email, plan: account.planType)
                if request.quota {
                    expectedID = 2
                    send(["id": 2, "method": "account/rateLimits/read"])
                } else { readHistoryOrFinish() }
            case 2:
                guard let account else { throw CodexUsageFailure.invalidResponse }
                do { self.result.quota = try CodexUsageParser.snapshot(from: data, account: account, at: now()) }
                catch { self.result.quotaIssue = CodexUsageIssue.from(error as? CodexUsageFailure ?? .invalidResponse) }
                readHistoryOrFinish()
            case 3:
                do { self.result.history = try CodexUsageParser.history(from: data, at: now()) }
                catch { self.result.historyIssue = CodexUsageIssue.from(error as? CodexUsageFailure ?? .invalidResponse) }
                finish(.success(self.result))
            default: break
            }
        } catch {
            finish(.failure(error as? CodexUsageFailure ?? .invalidResponse))
        }
    }

    private func readHistoryOrFinish() {
        guard request.history else { finish(.success(result)); return }
        expectedID = 3
        send(["id": 3, "method": "account/usage/read"])
    }

    private func send(_ message: [String: Any]) {
        guard !finished, let input else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            try input.write(contentsOf: data)
        } catch {
            finish(.failure(CodexUsageFailure.connection))
        }
    }

    private func finish(_ completion: Result<CodexUsageResult, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        if let reader {
            reader.cancel()
        } else {
            try? output?.close()
        }
        reader = nil
        output = nil
        try? input?.close()
        input = nil
        if let process, process.isRunning {
            process.terminate()
            queue.asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        let callback = continuation
        continuation = nil
        // A history transport failure must not discard a quota already fetched.
        if case .failure(let error) = completion, expectedID == 3, result.account != nil,
           !(error is CancellationError) {
            result.historyIssue = CodexUsageIssue.from(error)
            callback?.resume(returning: result)
        } else { callback?.resume(with: completion) }
    }
}
