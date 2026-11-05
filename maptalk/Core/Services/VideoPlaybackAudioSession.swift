import AVFoundation
import Foundation
import UIKit

nonisolated enum VideoPlaybackPolicy {
    static func shouldPlay(isVisible: Bool, isSelected: Bool, isSceneActive: Bool) -> Bool {
        isVisible && isSelected && isSceneActive
    }
}

@MainActor
protocol VideoAudioSessionControlling: AnyObject {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: VideoAudioSessionControlling {}

/// The selected, visible video takes an audible session, including compact
/// cards. We do not change device volume, routes, or background modes.
@MainActor
final class VideoPlaybackAudioSession {
    static let shared = VideoPlaybackAudioSession(session: AVAudioSession.sharedInstance())

    private let session: any VideoAudioSessionControlling
    private var owner: UUID?
    private var stopPlayback: (() -> Void)?
    private var previousConfiguration: Configuration?
    private var sessionIsActive = false
    private var releaseTask: Task<Void, Never>?
    private var releaseID: UUID?
    private let releaseDelay: Duration
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var isInterrupted = false
    private var isInBackground = false

    private struct Configuration {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    init(session: any VideoAudioSessionControlling,
         releaseDelay: Duration = .milliseconds(150),
         notificationCenter: NotificationCenter = .default) {
        self.session = session
        self.releaseDelay = releaseDelay
        self.notificationCenter = notificationCenter
        observers = [
            notificationCenter.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                           object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isInBackground = true
                    self?.stopAndRelinquish()
                }
            },
            notificationCenter.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                           object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isInBackground = false
                    // An interruption may end while the app is suspended,
                    // without delivering its matching end notification. Let
                    // the next visible player ask the OS for activation again.
                    self?.isInterrupted = false
                }
            },
            notificationCenter.addObserver(forName: AVAudioSession.interruptionNotification,
                                           object: nil, queue: .main) { [weak self] notification in
                let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                MainActor.assumeIsolated {
                    guard let self, let value,
                          let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
                    self.isInterrupted = type == .began
                    if self.isInterrupted { self.stopAndRelinquish() }
                }
            }
        ]
    }

    deinit {
        releaseTask?.cancel()
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    func acquire(owner requestedOwner: UUID, stopPlayback: @escaping () -> Void) -> Bool {
        guard !isInterrupted, !isInBackground else { return false }
        cancelPendingRelease()
        if owner == requestedOwner, sessionIsActive, hasPlaybackConfiguration { return true }
        // A newly selected video must silence its predecessor even if SwiftUI
        // updates the incoming page before it updates/removes the outgoing one.
        // Revoke its lease first: its stop callback also calls release(), and
        // that stale release must not deactivate the session during handoff.
        let stopPreviousPlayback = self.stopPlayback
        owner = nil
        self.stopPlayback = nil
        stopPreviousPlayback?()

        if sessionIsActive, hasPlaybackConfiguration {
            owner = requestedOwner
            self.stopPlayback = stopPlayback
            return true
        }

        // Another subsystem (notably camera capture) can change the shared
        // session. Never restore an obsolete configuration over its settings.
        sessionIsActive = false
        previousConfiguration = nil
        let previous = Configuration(category: session.category, mode: session.mode,
                                     options: session.categoryOptions)
        do {
            // Mixing avoids taking over music/podcasts playing in another app.
            // Playback keeps the selected video audible in Silent mode.
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            previousConfiguration = previous
            sessionIsActive = true
            owner = requestedOwner
            self.stopPlayback = stopPlayback
            return true
        } catch {
            // Higher-priority audio may deny activation. Keep the video muted
            // and restore the preexisting category instead of forcing a route.
            restore(previous)
            return false
        }
    }

    /// The owner pauses/mutes its AVPlayer before releasing the session.
    func release(owner releasedOwner: UUID) {
        guard owner == releasedOwner else { return }
        owner = nil
        stopPlayback = nil
        // SwiftUI may remove the outgoing page one update before selecting the
        // incoming page. Keep only the audio session warm briefly, never the
        // old player's sound; its caller already paused/muted it.
        cancelPendingRelease()
        if releaseDelay <= .zero {
            relinquishSession()
            return
        }
        let id = UUID()
        releaseID = id
        let delay = releaseDelay
        releaseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, self.releaseID == id, self.owner == nil else { return }
            self.relinquishSession()
        }
    }

    private var hasPlaybackConfiguration: Bool {
        session.category == .playback && session.mode == .moviePlayback
            && session.categoryOptions == [.mixWithOthers]
    }

    private func cancelPendingRelease() {
        releaseTask?.cancel()
        releaseTask = nil
        releaseID = nil
    }

    private func stopAndRelinquish() {
        let stop = stopPlayback
        owner = nil
        stopPlayback = nil
        stop?()
        relinquishSession()
    }

    private func relinquishSession() {
        cancelPendingRelease()
        if sessionIsActive, hasPlaybackConfiguration {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            if let previousConfiguration { restore(previousConfiguration) }
        }
        sessionIsActive = false
        previousConfiguration = nil
    }

    private func restore(_ configuration: Configuration) {
        try? session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
    }
}
