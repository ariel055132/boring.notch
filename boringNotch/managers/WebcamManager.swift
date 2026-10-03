//
//  WebcamManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan Goswami on 19/08/24.
//
import AVFoundation
import SwiftUI

protocol CameraCaptureControlling: Sendable {
    func start() async throws
    func stop() async
    @MainActor func makePreviewLayer() -> AVCaptureVideoPreviewLayer
}

@MainActor
final class WebcamManager: NSObject, ObservableObject {
    static let shared = WebcamManager()

    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var isSessionRunning = false
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined
    @Published var cameraAvailable = false

    private let capture: any CameraCaptureControlling
    private var observers: [NSObjectProtocol] = []
    private var operation: Task<Void, Never>?
    private var revision: UInt = 0
    private var wantsRunning = false

    private override convenience init() {
        self.init(capture: CameraCaptureSession())
    }

    init(capture: any CameraCaptureControlling) {
        self.capture = capture
        super.init()
        for name in [Notification.Name.AVCaptureDeviceWasConnected, .AVCaptureDeviceWasDisconnected] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let disconnected = notification.name == .AVCaptureDeviceWasDisconnected
                MainActor.assumeIsolated {
                    if disconnected {
                        self?.stopSession()
                    }
                    self?.checkCameraAvailability()
                }
            })
        }
        checkCameraAvailability()
    }

    isolated deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let capture = capture
        let previous = operation
        Task {
            await previous?.value
            await capture.stop()
        }
    }

    func checkAndRequestVideoAuthorization() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorizationStatus {
        case .authorized:
            checkCameraAvailability()
        case .notDetermined:
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                self?.authorizationStatus = granted ? .authorized : .denied
                self?.checkCameraAvailability()
            }
        default:
            break
        }
    }

    func checkCameraAvailability() {
        cameraAvailable = !AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.isEmpty
    }

    func startSession() {
        guard !wantsRunning else { return }
        wantsRunning = true
        revision &+= 1
        let requestedRevision = revision
        let previous = operation
        let capture = capture
        operation = Task { [weak self] in
            await previous?.value
            guard let self, revision == requestedRevision, wantsRunning else { return }
            do {
                try await capture.start()
                // A close or disconnect may have arrived while the camera was starting.
                guard revision == requestedRevision, wantsRunning else { return }
                previewLayer = capture.makePreviewLayer()
                isSessionRunning = true
                cameraAvailable = true
            } catch {
                guard revision == requestedRevision else { return }
                wantsRunning = false
                isSessionRunning = false
                previewLayer = nil
                checkCameraAvailability()
                NSLog("Failed to start camera: %@", error.localizedDescription)
            }
        }
    }

    func stopSession() {
        wantsRunning = false
        revision &+= 1
        previewLayer = nil
        isSessionRunning = false
        let previous = operation
        let capture = capture
        operation = Task {
            await previous?.value
            await capture.stop()
        }
    }
}

/// AVFoundation bridge: configuration, start, and stop run exclusively on `queue`.
/// The session reference is immutable. The only main-actor access attaches it to
/// an AVCaptureVideoPreviewLayer; UI code never configures or starts the session.
private final class CameraCaptureSession: CameraCaptureControlling, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "BoringNotch.CameraCaptureSession", qos: .userInitiated)
    private var configured = false // Accessed only on queue.

    @MainActor func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try configureIfNeeded()
                    if !session.isRunning { session.startRunning() }
                    guard session.isRunning else { throw CaptureError.failedToStart }
                    continuation.resume()
                } catch {
                    cleanup()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                cleanup()
                continuation.resume()
            }
        }
    }

    private func configureIfNeeded() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !configured else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CaptureError.accessDenied
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified
        )
        guard let device = discovery.devices.first else { throw CaptureError.deviceUnavailable }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard session.canAddInput(input) else { throw CaptureError.configurationFailed }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        if session.canAddOutput(output) { session.addOutput(output) }
        configured = true
    }

    private func cleanup() {
        dispatchPrecondition(condition: .onQueue(queue))
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        configured = false
    }

    private enum CaptureError: LocalizedError {
        case accessDenied, deviceUnavailable, configurationFailed, failedToStart
        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Camera access denied"
            case .deviceUnavailable: return "No camera devices available"
            case .configurationFailed: return "Cannot add camera input"
            case .failedToStart: return "The camera session could not start"
            }
        }
    }
}
