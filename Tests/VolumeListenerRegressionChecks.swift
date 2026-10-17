import AppKit
import CoreAudio
import Foundation

// Only the unrelated HUD coordinator is a Swift stub. Audio calls retain their
// real C declarations and block bridging, with definitions supplied by the C
// fixture at link time. A Swift-only stub would miss the runtime isolation trap.
enum SneakContentType { case volume }

@MainActor
final class BoringViewCoordinator {
    static let shared = BoringViewCoordinator()
    func toggleSneakPeek(status: Bool, type: SneakContentType, value: CGFloat) {}
}

@main
private struct VolumeListenerRegressionChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: message, code: 1) }
        checks += 1
    }

    @MainActor private static func eventually(
        _ message: String, _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "Timed out: \(message)", code: 2)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(condition(), message)
    }

    @MainActor static func main() async throws {
        let usesMasterVolume = CommandLine.arguments.contains("master")
        BNConfigureAudioFixture(usesMasterVolume)
        let manager = VolumeManager.shared
        try await eventually("initial volume") { manager.rawVolume == 0.25 }

        let volumeElements: [UInt32] = usesMasterVolume ? [kAudioObjectPropertyElementMain] : [1, 2]
        try expect(BNVolumeListenerCount() == volumeElements.count,
                   "Register master volume or both fallback channels")
        try expect(BNAudioListenerCount() == volumeElements.count + 2,
                   "Register output-device and mute notifications as well")

        for (index, element) in volumeElements.enumerated() {
            let nextVolume = Float32(index + 1) / 2
            BNSetAudioFixtureState(1, nextVolume, 0)
            try expect(BNNotifyAudioFixture(kAudioDevicePropertyVolumeScalar, element), "Volume listener exists")
            try await eventually("volume notification updates published state") {
                manager.rawVolume == nextVolume
            }
        }

        BNSetAudioFixtureState(1, manager.rawVolume, 1)
        try expect(BNNotifyAudioFixture(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain), "Mute listener exists")
        try await eventually("mute notification updates published state") { manager.isMuted }
        BNSetAudioFixtureState(1, manager.rawVolume, 0)
        try expect(BNNotifyAudioFixture(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain), "Unmute listener exists")
        try await eventually("unmute notification updates published state") { !manager.isMuted }

        BNSetAudioFixtureState(2, 0.125, 1)
        try expect(BNNotifyAudioFixture(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyElementMain),
                   "Default-output listener exists")
        try await eventually("output-device notification reads the new device") {
            manager.rawVolume == 0.125 && manager.isMuted
        }
        try expect(manager.lastChangeAt > .distantPast, "Notifications update the change timestamp")
        print("Passed \(checks) volume listener checks (\(usesMasterVolume ? "master" : "channels"))")
    }
}
