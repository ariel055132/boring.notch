import Darwin
import Foundation

struct ClaudeUsageRenewalLaunch: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL

    static func discover(environment: [String: String] = ProcessInfo.processInfo.environment,
                         home: URL = URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()),
                         isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) throws -> Self {
        let standard = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        let candidates = [home.appendingPathComponent(".local/bin/claude")]
            + (paths + standard).map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            + [home.appendingPathComponent(".npm-global/bin/claude")]
        guard let executable = candidates.first(where: { isExecutable($0.path) }) else {
            throw ClaudeUsageFailure.renewalUnavailable
        }
        // Use the same default account as ClaudeUsageKeychain. Never inherit a
        // different provider, config directory, token, runtime injector or hook.
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"]
        var childEnvironment = environment.filter { allowed.contains($0.key) }
        childEnvironment["HOME"] = home.path
        childEnvironment["PATH"] = (paths + standard).joined(separator: ":")
        childEnvironment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return Self(executable: executable,
                    arguments: ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
                                "--verbose", "--safe-mode", "--no-session-persistence", "--setting-sources", "",
                                "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--tools", "",
                                "--permission-mode", "dontAsk"],
                    environment: childEnvironment, workingDirectory: URL(fileURLWithPath: "/"))
    }
}

// Only initialize/get_usage control messages are sent. There is no user prompt,
// model turn, login command or token transport. Claude Code owns refresh and its
// cross-process credential lock. Its experimental protocol may be unavailable;
// never fall back to a chat prompt or scrape stderr in that case.
final class ClaudeUsageRenewalProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "theboringteam.boringnotch.claude-renewal", qos: .utility)
    private let launch: ClaudeUsageRenewalLaunch
    private let timeout: TimeInterval
    private let maximumBytes: Int
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Void, Error>?
    private var buffer = Data()
    private var bytesRead = 0
    private var expectedID = "initialize"
    private var finished = false

    init(launch: ClaudeUsageRenewalLaunch, timeout: TimeInterval = 90, maximumBytes: Int = 1_048_576) {
        self.launch = launch
        self.timeout = timeout
        self.maximumBytes = maximumBytes
    }

    static func renew() async throws {
        try await Self(launch: ClaudeUsageRenewalLaunch.discover()).run()
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ continuation: CheckedContinuation<Void, Error>) {
        guard !finished else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = launch.executable
        child.arguments = launch.arguments
        child.environment = launch.environment
        child.currentDirectoryURL = launch.workingDirectory
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.drain()
                if !self.finished { self.finish(.failure(ClaudeUsageFailure.renewalFailed)) }
            }
        }
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        do { try child.run() }
        catch { finish(.failure(ClaudeUsageFailure.renewalUnavailable)); return }
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        _ = fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1)
        let descriptor = output!.fileDescriptor
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
            finish(.failure(ClaudeUsageFailure.connection)); return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        let handle = output!
        source.setCancelHandler { try? handle.close() }
        reader = source
        source.resume()
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { [weak self] in self?.finish(.failure(ClaudeUsageFailure.timedOut)) }
        timer = deadline
        deadline.resume()
        send(id: "initialize", request: ["subtype": "initialize"])
    }

    private func send(id: String, request: [String: Any]) {
        guard !finished, let input else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: ["type": "control_request", "request_id": id, "request": request])
            data.append(10)
            try input.write(contentsOf: data)
        } catch { finish(.failure(ClaudeUsageFailure.connection)) }
    }

    private func drain() {
        guard !finished, let output else { return }
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !finished {
            let count = Darwin.read(output.fileDescriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN { finish(.failure(ClaudeUsageFailure.connection)) }
                return
            }
            if count == 0 { finish(.failure(ClaudeUsageFailure.renewalFailed)); return }
            bytesRead += count
            guard bytesRead <= maximumBytes else { finish(.failure(ClaudeUsageFailure.invalidResponse)); return }
            buffer.append(contentsOf: chunk.prefix(count))
            while !finished, let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty { receive(line) }
            }
        }
    }

    private func receive(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = message["type"] as? String else {
            finish(.failure(ClaudeUsageFailure.invalidResponse)); return
        }
        // Interactive authorization, tool requests or assistant/model output
        // are not part of this protocol. Stop instead of answering them.
        if type == "system" { return }
        guard type == "control_response", let reply = message["response"] as? [String: Any],
              let id = reply["request_id"] as? String else {
            finish(.failure(ClaudeUsageFailure.renewalUnavailable)); return
        }
        guard id == expectedID else { return }
        guard reply["subtype"] as? String == "success", let body = reply["response"] as? [String: Any] else {
            finish(.failure(ClaudeUsageFailure.renewalUnavailable)); return
        }
        if id == "initialize" {
            expectedID = "usage"
            send(id: "usage", request: ["subtype": "get_usage", "skip_behaviors": true])
        } else {
            guard let session = body["session"] as? [String: Any],
                  isZero(session["total_cost_usd"]), isZero(session["total_api_duration_ms"]),
                  let models = session["model_usage"] as? [String: Any], models.isEmpty,
                  body["behaviors"] is NSNull else {
                finish(.failure(ClaudeUsageFailure.invalidResponse)); return
            }
            // get_usage can swallow a network/auth error or use a cached result.
            // The caller MUST re-read credentials and verify them after this ack.
            finish(.success(()))
        }
    }

    private func isZero(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == 0
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        if let reader { reader.cancel() } else { try? output?.close() }
        reader = nil; output = nil
        try? input?.close(); input = nil
        if let process, process.isRunning {
            process.terminate()
            queue.asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        buffer.removeAll(keepingCapacity: false)
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
