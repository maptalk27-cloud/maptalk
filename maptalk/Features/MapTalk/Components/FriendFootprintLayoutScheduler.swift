import Combine
import Foundation
import MapKit

/// Coalesces layout inputs without publishing camera motion at frame rate.
/// Buttons remain independent: only automatic marker layout waits for rest.
@MainActor
final class FriendFootprintLayoutScheduler: ObservableObject {
    private static let quietInterval: TimeInterval = 0.12
    private var lastMotion: TimeInterval = -.infinity
    private var lastRequest: TimeInterval = -.infinity
    private var pendingUpdate: (() -> Void)?
    private var canApply: (() -> Bool)?
    private var task: Task<Void, Never>?
    private(set) var visibleRegion: MKCoordinateRegion?

    func noteCameraMotion(region: MKCoordinateRegion) {
        lastMotion = ProcessInfo.processInfo.systemUptime
        visibleRegion = region
    }

    func request(canApply: @escaping () -> Bool, update: @escaping () -> Void) {
        lastRequest = ProcessInfo.processInfo.systemUptime
        self.canApply = canApply
        pendingUpdate = update
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - max(lastMotion, lastRequest) >= Self.quietInterval,
                      self.canApply?() == true else { continue }
                let update = pendingUpdate
                pendingUpdate = nil
                self.canApply = nil
                task = nil
                update?()
                return
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingUpdate = nil
        canApply = nil
        visibleRegion = nil
    }

    deinit { task?.cancel() }
}
