import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers
@testable import Boring_Notch

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private actor ControlledCamera: CameraCaptureControlling {
    private var pending: [CheckedContinuation<Void, Error>] = []
    private(set) var starts = 0
    private(set) var stops = 0

    func start() async throws {
        starts += 1
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func stop() async { stops += 1 }
    func finishStart(failing: Bool = false) {
        let continuation = pending.removeFirst()
        if failing { continuation.resume(throwing: CheckFailure(description: "simulated camera failure")) }
        else { continuation.resume() }
    }
    @MainActor func makePreviewLayer() -> AVCaptureVideoPreviewLayer { AVCaptureVideoPreviewLayer() }
}

@main
private struct ConcurrencyRegressionChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(description: message) }
        checks += 1
    }

    @MainActor private static func eventually(_ message: String, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CheckFailure(description: "Timed out: \(message)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async throws {
        checks += CalendarRegressionChecks.run()
        try await cameraLifecycle()
        checks += try await XPCRegressionChecks.run()
        try await inheritedIsolation()
        try await providerCallbacks()
        try await compression()
        print("Passed \(checks) concurrency regression checks")
    }

    @MainActor private static func cameraLifecycle() async throws {
        let capture = ControlledCamera()
        let manager = WebcamManager(capture: capture)
        manager.startSession()
        manager.startSession()
        try await eventually("one camera start") { await capture.starts == 1 }
        manager.stopSession()
        await capture.finishStart()
        try await eventually("stop after pending start") { await capture.stops == 1 }
        try expect(!manager.isSessionRunning && manager.previewLayer == nil, "Closing during startup must not reopen the preview")
        try expect(await capture.starts == 1, "Repeated start must not duplicate capture configuration")

        manager.startSession()
        try await eventually("camera restart") { await capture.starts == 2 }
        await capture.finishStart()
        try await eventually("preview after restart") { manager.isSessionRunning }
        try expect(manager.previewLayer != nil, "Successful startup must publish a preview")
        manager.stopSession()
        manager.startSession()
        manager.stopSession()
        try await eventually("rapid toggle cleanup") { await capture.stops == 3 }
        try expect(!manager.isSessionRunning && manager.previewLayer == nil, "Rapid open/close must leave the camera closed")
        try expect(await capture.starts == 2, "Superseded starts must not start hardware")

        manager.startSession()
        try await eventually("failing startup") { await capture.starts == 3 }
        await capture.finishStart(failing: true)
        try await eventually("retry after failure") {
            manager.startSession()
            return await capture.starts == 4
        }
        try expect(!manager.isSessionRunning && manager.previewLayer == nil, "Startup failure must leave no active preview")
        await capture.finishStart()
        try await eventually("retry preview") { manager.isSessionRunning }
        try expect(manager.isSessionRunning, "Camera must support retry after a failed startup")
        manager.stopSession()
        try await eventually("final camera cleanup") { await capture.stops == 4 }
    }

    @MainActor private static func inheritedIsolation() async throws {
        let url = FileManager.default.temporaryDirectory
        let value = await url.accessSecurityScopedResource { _ in
            MainActor.assertIsolated()
            await Task.yield()
            MainActor.assertIsolated()
            return 42
        }
        try expect(value == 42, "Security-scoped callback must preserve the caller's actor across suspension")
        let result = await [url].accessSecurityScopedResources { urls in
            MainActor.assertIsolated()
            await Task.yield()
            return urls.count
        }
        try expect(result == 1, "Multiple-file access must preserve values and actor isolation")
        do {
            let _: Int = try await url.accessSecurityScopedResource { _ in
                await Task.yield()
                throw CheckFailure(description: "expected failure")
            }
            throw CheckFailure(description: "Security-scoped access swallowed an error")
        } catch let error as CheckFailure {
            try expect(error.description == "expected failure", "Security-scoped access must propagate errors")
        }
    }

    @MainActor private static func providerCallbacks() async throws {
        let provider = NSItemProvider()
        let payload = Data("Background provider callback".utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all) { completion in
            DispatchQueue.global().async { completion(payload, nil) }
            return nil
        }
        let loaded = await provider.loadData()
        try expect(loaded == payload, "Data from a background provider callback must reach the caller unchanged")
        try expect(provider.suggestedName == nil, "Raw data must not invent a filename")
        let unsupported = NSItemProvider()
        try expect(await unsupported.loadData() == nil, "Unsupported item providers must return nil")
    }

    @MainActor private static func compression() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boring-notch-regression-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sample.txt")
        let contents = Data("Swift 6 ZIP regression".utf8)
        try contents.write(to: file)
        let archive = await TemporaryFileStorageService.shared.createZip(from: [file])
        try expect(archive != nil, "Existing files must compress successfully")
        if let archive {
            defer { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: archive) }
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", archive.path, file.lastPathComponent]
            process.standardOutput = output
            try process.run()
            let uncompressed = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try expect(process.terminationStatus == 0 && uncompressed == contents, "Archive contents must match the source")
        }
        let missing = await TemporaryFileStorageService.shared.createZip(from: [folder.appendingPathComponent("missing.txt")])
        try expect(missing == nil, "Compression failure must be reported as nil for the UI failure branch")
        try expect(try Data(contentsOf: file) == contents, "Compression must preserve original files")
    }
}
