import Darwin
import Foundation

// /usr/bin/security keeps the same apple-tool partition used when Claude Code
// rotates its credential. Raw credentials stay in this pipe and the helper.
// The CLI has no no-UI flag: background callers MUST pass the metadata preflight.
final class ClaudeUsageSecurityCommand: @unchecked Sendable {
    private let queue = DispatchQueue(label: "theboringteam.boringnotch.claude-keychain", qos: .utility)
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let maximumBytes: Int
    private var process: Process?
    private var output: FileHandle?
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private var exitStatus: Int32?
    private var reachedEOF = false
    private var finished = false

    static func read(target: ClaudeUsageSecurityTarget?, allowInteraction: Bool) async throws -> Data {
        guard target != nil || allowInteraction else { throw ClaudeUsageFailure.permissionRequired }
        var arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        if let target { arguments += ["-a", target.account, target.keychainPath] }
        return try await Self(executable: URL(fileURLWithPath: "/usr/bin/security"),
                              arguments: arguments, timeout: allowInteraction ? 60 : 10).read()
    }

    // The executable seam is used only by offline process fixtures.
    init(executable: URL, arguments: [String], timeout: TimeInterval = 10,
         maximumBytes: Int = ClaudeUsageParser.maximumResponseBytes + 1) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.maximumBytes = maximumBytes
    }

    func read() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ continuation: CheckedContinuation<Data, Error>) {
        guard !finished else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let child = Process()
        let stdout = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                             "HOME": NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()]
        child.currentDirectoryURL = URL(fileURLWithPath: "/")
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            guard let self else { return }
            self.queue.async { self.didExit(child.terminationStatus) }
        }
        process = child
        output = stdout.fileHandleForReading
        do { try child.run() }
        catch { finish(.failure(ClaudeUsageFailure.connection)); return }
        try? stdout.fileHandleForWriting.close()
        let descriptor = stdout.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
            finish(.failure(ClaudeUsageFailure.connection)); return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        let handle = stdout.fileHandleForReading
        source.setCancelHandler { try? handle.close() }
        reader = source
        source.resume()
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { [weak self] in self?.finish(.failure(ClaudeUsageFailure.timedOut)) }
        timer = deadline
        deadline.resume()
    }

    private func drain() {
        guard !finished, !reachedEOF, let output else { return }
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !finished {
            let count = Darwin.read(output.fileDescriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN { finish(.failure(ClaudeUsageFailure.connection)) }
                return
            }
            if count == 0 {
                reachedEOF = true
                reader?.cancel()
                reader = nil
                self.output = nil
                completeIfReady()
                return
            }
            guard buffer.count + count <= maximumBytes else {
                finish(.failure(ClaudeUsageFailure.invalidResponse)); return
            }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }

    private func didExit(_ status: Int32) {
        guard !finished else { return }
        exitStatus = status
        drain()
        completeIfReady()
    }

    private func completeIfReady() {
        guard reachedEOF, let status = exitStatus, !finished else { return }
        guard status == 0 else {
            // Security's OSStatus is truncated to the process exit byte. Never
            // forward stderr or even successful-looking stdout from a failure.
            finish(.failure(status == 44 ? ClaudeUsageFailure.notSignedIn : .permissionRequired))
            return
        }
        if buffer.last == 10 { buffer.removeLast() } // security -w adds one newline.
        guard !buffer.isEmpty else { finish(.failure(ClaudeUsageFailure.notSignedIn)); return }
        finish(.success(buffer))
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        if let reader { reader.cancel() }
        else { try? output?.close() }
        reader = nil
        output = nil
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

enum ClaudeUsageCredentialReader {
    static func read(allowInteraction: Bool,
                     nativeRead: @Sendable () throws -> Data = { try ClaudeUsageKeychain.read(allowInteraction: false) },
                     preflight: @Sendable () throws -> ClaudeUsageSecurityTarget = {
                         try ClaudeUsageKeychain.withInteraction(false) { try ClaudeUsageSecurityPreflight.inspect() }
                     },
                     command: @Sendable (ClaudeUsageSecurityTarget?, Bool) async throws -> Data = {
                         try await ClaudeUsageSecurityCommand.read(target: $0, allowInteraction: $1)
                     }) async throws -> Data {
        do { return try nativeRead() }
        catch ClaudeUsageFailure.permissionRequired {
            let target: ClaudeUsageSecurityTarget?
            do { target = try preflight() }
            catch ClaudeUsageFailure.permissionRequired {
                guard allowInteraction else { throw ClaudeUsageFailure.permissionRequired }
                // Only explicit Connect may ask the system tool for new access.
                target = nil
            }
            return try await command(target, allowInteraction)
        }
    }
}
