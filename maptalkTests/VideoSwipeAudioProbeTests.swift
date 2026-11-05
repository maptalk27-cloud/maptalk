import AVFoundation
import Foundation
import Testing
@testable import maptalk

/// Manual diagnostic: run this suite alone, without another audio-playing test.
/// Simulator timings identify synchronous work, not physical-device latency.
@Suite(.serialized)
struct VideoSwipeAudioProbeTests {
    @Test @MainActor
    func measuresRealAudioSessionWorkDuringFiveVideoHandoffs() async throws {
        let session = AVAudioSession.sharedInstance()
        let originalCategory = session.category
        let originalMode = session.mode
        let originalOptions = session.categoryOptions
        let timed = TimedVideoAudioSession(session: session)
        let audio = VideoPlaybackAudioSession(session: timed)
        var currentOwner = UUID()
        defer {
            audio.release(owner: currentOwner)
            try? session.setCategory(originalCategory, mode: originalMode, options: originalOptions)
        }

        let firstOwner = currentOwner
        try #require(audio.acquire(owner: firstOwner) {
            // Matches PlayerContainerView's stop -> setPlaying(false) -> release.
            audio.release(owner: firstOwner)
        })

        for index in 1...5 {
            let incomingOwner = UUID()
            if index.isMultiple(of: 2) {
                // Also exercise SwiftUI's outgoing-before-incoming order.
                audio.release(owner: currentOwner)
            }
            let start = ProcessInfo.processInfo.systemUptime
            let acquired = audio.acquire(owner: incomingOwner) {
                audio.release(owner: incomingOwner)
            }
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            print("VIDEO_AUDIO_PROBE handoff=\(index) mainThread=\(Thread.isMainThread) elapsedMS=\(elapsed)")
            currentOwner = incomingOwner
            try #require(acquired)
        }
        audio.release(owner: currentOwner)
        try await Task.sleep(for: .milliseconds(250))

        let activationCount = timed.events.filter { $0.operation == "setActive(true)" }.count
        let deactivationCount = timed.events.filter { $0.operation == "setActive(false)" }.count
        let categoryCount = timed.events.filter { $0.operation.hasPrefix("setCategory") }.count
        let total = timed.events.reduce(0) { $0 + $1.milliseconds }
        let maximum = timed.events.map(\.milliseconds).max() ?? 0
        print("VIDEO_AUDIO_PROBE summary calls=\(timed.events.count) categories=\(categoryCount) activations=\(activationCount) deactivations=\(deactivationCount) totalMS=\(total) maxCallMS=\(maximum)")
        // No latency assertion: this records actual local behavior without
        // treating a fast simulator audio backend as evidence of smooth UI.
        #expect(activationCount == 1)
        #expect(deactivationCount == 1)
        #expect(categoryCount == 2)
        #expect(timed.events.count == 4)
        let allCallsSucceeded = timed.events.allSatisfy { $0.succeeded }
        #expect(allCallsSucceeded)
    }
}

@MainActor
private final class TimedVideoAudioSession: VideoAudioSessionControlling {
    struct Event {
        let operation: String
        let milliseconds: Double
        let succeeded: Bool
    }

    private let session: AVAudioSession
    private(set) var events: [Event] = []

    init(session: AVAudioSession) { self.session = session }

    var category: AVAudioSession.Category { session.category }
    var mode: AVAudioSession.Mode { session.mode }
    var categoryOptions: AVAudioSession.CategoryOptions { session.categoryOptions }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {
        try measure("setCategory(\(category.rawValue),\(mode.rawValue))") {
            try session.setCategory(category, mode: mode, options: options)
        }
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        try measure("setActive(\(active))") {
            try session.setActive(active, options: options)
        }
    }

    private func measure(_ operation: String, body: () throws -> Void) throws {
        let start = ProcessInfo.processInfo.systemUptime
        var succeeded = false
        defer {
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            events.append(.init(operation: operation, milliseconds: milliseconds, succeeded: succeeded))
            print("VIDEO_AUDIO_PROBE call=\(events.count) operation=\(operation) mainThread=\(Thread.isMainThread) elapsedMS=\(milliseconds) success=\(succeeded)")
        }
        try body()
        succeeded = true
    }
}
