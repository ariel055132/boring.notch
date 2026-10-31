import Foundation
import Darwin

// All Process, descriptor and continuation state is confined to queue. A result is
// delivered only after termination, including timeout/cancellation, so children are reaped.
final class DeviceBatteryProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "theboringteam.boringnotch.device-battery-process", qos: .utility)
    private let executable: URL
    private let arguments: [String]
    private let timeout: TimeInterval
    private let outputLimit: Int
    private var process: Process?
    private var pipe: Pipe?
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var output = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var failure: DeviceBatterySourceState?
    private var cancelled = false
    private var exited = false
    private var eof = false

    init(executable: URL, arguments: [String] = [], timeout: TimeInterval = 12, outputLimit: Int = 1_048_576) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.abort(.cancelled)
            }
        }
    }

    private func start(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
        guard !cancelled else {
            exited = true; eof = true; failure = .cancelled; completeIfReady(); return
        }
        let child = Process()
        let pipe = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        child.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.queue.async {
                self.exited = true
                if process.terminationStatus != 0 && self.failure == nil { self.failure = .unavailable }
                self.completeIfReady()
            }
        }
        self.process = child
        self.pipe = pipe
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable(fd) }
        source.setCancelHandler { try? pipe.fileHandleForReading.close() }
        reader = source
        source.resume()
        do {
            try child.run()
            try? pipe.fileHandleForWriting.close()
        } catch {
            try? pipe.fileHandleForWriting.close()
            exited = true; eof = true; failure = .toolUnavailable
            completeIfReady()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.abort(.timedOut) }
        self.timer = timer
        timer.resume()
    }

    private func readAvailable(_ fd: Int32) {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                guard output.count + count <= outputLimit else { abort(.invalidResponse); return }
                output.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                reader?.cancel(); reader = nil
                eof = true; completeIfReady(); return
            } else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR { abort(.unavailable); return }
        }
    }

    private func abort(_ reason: DeviceBatterySourceState) {
        guard continuation != nil else { return }
        if failure == nil { failure = reason }
        eof = true
        reader?.cancel()
        reader = nil
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        completeIfReady()
    }

    private func completeIfReady() {
        guard exited, eof, let continuation else { return }
        self.continuation = nil
        timer?.cancel(); timer = nil
        reader?.cancel(); reader = nil
        process?.terminationHandler = nil
        process = nil; pipe = nil
        if let failure { continuation.resume(throwing: failure) }
        else { continuation.resume(returning: output) }
    }
}
