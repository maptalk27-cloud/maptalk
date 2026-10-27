import AVFoundation
import Foundation

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

/// Only an explicitly opened video takes an audible session. Compact previews
/// never acquire it; we do not change device volume, routes, or background modes.
@MainActor
final class VideoPlaybackAudioSession {
    static let shared = VideoPlaybackAudioSession(session: AVAudioSession.sharedInstance())

    private let session: any VideoAudioSessionControlling
    private var owner: UUID?
    private var stopPlayback: (() -> Void)?
    private var previousConfiguration: Configuration?

    private struct Configuration {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    init(session: any VideoAudioSessionControlling) {
        self.session = session
    }

    func acquire(owner requestedOwner: UUID, stopPlayback: @escaping () -> Void) -> Bool {
        if owner == requestedOwner { return true }
        // A newly selected video must silence its predecessor even if SwiftUI
        // updates the incoming page before it updates/removes the outgoing one.
        if let previousOwner = owner {
            self.stopPlayback?()
            release(owner: previousOwner)
        }
        let previous = Configuration(category: session.category, mode: session.mode,
                                     options: session.categoryOptions)
        do {
            // Mixing avoids taking over music/podcasts playing in another app.
            // Playback makes an intentionally opened video audible in Silent mode.
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            previousConfiguration = previous
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
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        if let previousConfiguration { restore(previousConfiguration) }
        previousConfiguration = nil
    }

    private func restore(_ configuration: Configuration) {
        try? session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
    }
}
