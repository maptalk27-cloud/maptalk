import AVFoundation
import CoreLocation
import SwiftUI
import Testing
import UIKit
@testable import maptalk

@MainActor
@Suite(.serialized)
struct ExperiencePanelSizingTests {
    @Test(.timeLimit(.minutes(1)))
    func resizingExpandedPanelKeepsItsVideoPlayer() async throws {
        let source = try await VideoTestFixture.makeVideo(duration: 10)
        defer { try? FileManager.default.removeItem(at: source) }
        let reel = RealPost(id: UUID(), userId: UUID(), center: .init(latitude: 0, longitude: 0),
                            radiusMeters: 80, message: "A video", attachments: [.init(kind: .video(url: source, poster: nil))],
                            likes: [], comments: [], visibility: .privateOnly, createdAt: .now,
                            expiresAt: .now.addingTimeInterval(86_400))
        let detail = ExperienceDetailView(mode: .real(reel, nil))
        let panel = ExperienceDetailView.ExperiencePanel(data: detail.contentData(for: .real(reel, nil)),
            onRecentSharerSelected: nil, journeyProvider: { _ in nil }, userProvider: { _ in nil },
            onJourneyAvatarStackTap: nil, onUserSelected: { _ in }, onPOIContributorViewed: { _ in },
            isPOIContributorUnseen: { _ in false }, isPlaybackActive: false)
        let host = UIHostingController(rootView: panel)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 778))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let before = try #require(players(in: host.view).first)
        #expect(players(in: host.view).count == 1)
        let playerView = try #require(playerViews(in: host.view).first)
        let panelScroll = try #require(enclosingScrollView(of: playerView))
        #expect(!panelScroll.isScrollEnabled)
        #expect(abs(playerView.bounds.width - 402) < 1)
        #expect(abs(playerView.bounds.height - 536) < 1)

        // An interactive sheet drag can temporarily make a previously fitting
        // post taller than the viewport before either detent is committed.
        window.frame.size.height = 500
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let during = try #require(players(in: host.view).first)
        #expect(during === before, "Dragging must not swap the player when content starts to overflow")
        #expect(players(in: host.view).count == 1)
        #expect(panelScroll.isScrollEnabled, "Overflowing content must remain readable")

        window.frame.size.height = 778
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let after = try #require(players(in: host.view).first)
        #expect(after === before, "Cancelling a drag must preserve the same player and its position")
        #expect(players(in: host.view).count == 1)
        #expect(!panelScroll.isScrollEnabled)
        #expect(abs(playerView.bounds.width - 402) < 1)
        #expect(abs(playerView.bounds.height - 536) < 1)
    }

    private func players(in view: UIView) -> [AVPlayer] {
        playerViews(in: view).compactMap { ($0.layer as? AVPlayerLayer)?.player }
    }

    private func playerViews(in view: UIView) -> [UIView] {
        let own: [UIView] = view.layer is AVPlayerLayer ? [view] : []
        return own + view.subviews.flatMap { playerViews(in: $0) }
    }

    private func enclosingScrollView(of view: UIView) -> UIScrollView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView { return scrollView }
            ancestor = current.superview
        }
        return nil
    }
}
