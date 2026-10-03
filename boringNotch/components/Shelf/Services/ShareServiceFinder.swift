//
//  ShareServiceFinder.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-06.
//

import Cocoa

@MainActor
final class ShareServiceFinder: NSObject, @MainActor NSSharingServicePickerDelegate {
    private var onServicesCaptured: (([NSSharingService]) -> Void)?

    /// Keep AppKit sharing services on the main actor, including the timeout path.
    func findApplicableServices(for items: [Any], timeout: TimeInterval = 2.0) async -> [NSSharingService] {
        let dummyView = NSView(frame: .zero)
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        defer { picker.delegate = nil; onServicesCaptured = nil }

        var services: [NSSharingService] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var didResume = false
            var timeoutTask: Task<Void, Never>?
            onServicesCaptured = { captured in
                guard !didResume else { return }
                didResume = true
                services = captured
                timeoutTask?.cancel()
                continuation.resume()
            }
            timeoutTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(timeout)) }
                catch { return }
                guard !didResume else { return }
                didResume = true
                continuation.resume()
            }
            picker.show(relativeTo: dummyView.bounds, of: dummyView, preferredEdge: .minY)
        }
        return services
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker,
                              sharingServicesForItems items: [Any],
                              proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
        onServicesCaptured?(proposed)
        return proposed
    }
}
