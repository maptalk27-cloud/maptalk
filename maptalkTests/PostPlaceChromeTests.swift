import Combine
import CoreLocation
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import maptalk

@MainActor
@Suite(.serialized)
struct PostPlaceChromeTests {
    @Test
    func actualPostPagerRetainsRenderedChromeAcrossPhotoVideoSwipeCancelAndCommit() async throws {
        let fixture = try PostChromeHostingFixture()
        defer { fixture.dispose() }
        try await fixture.settle()
        let pager = try #require(fixture.horizontalPager())
        let initial = pager.contentOffset
        let width = pager.bounds.width
        try #require(width > 300)
        let baseline = try fixture.pixels()
        // Commit explicitly, as the native pager does at gesture idle. Direct
        // UIScrollView offsets exercise its actual partial-page rendering.
        for (step, commit) in [(0.4, false), (0.0, false), (1.0, true),
                               (0.6, false), (1.0, false), (0.0, true)] {
            let target = initial.x + width * step
            pager.setContentOffset(CGPoint(x: target, y: initial.y), animated: false)
            if commit { fixture.state.selection = fixture.posts[step == 1 ? 1 : 0].id }
            try await fixture.settle()
            #expect(abs(pager.contentOffset.x - target) < 2, "The actual native pager must reach the tested offset")
            let current = try fixture.pixels()
            for region in [CGRect(x: 12, y: 10, width: 230, height: 48),
                           CGRect(x: 250, y: 440, width: 128, height: 50)] {
                // Post actions are translucent secondary ink, unlike POI's
                // white glyphs. Include their strokes over either dark media
                // background, not just the brightest antialiased fragments.
                let before = baseline.whiteMask(in: region, minimumBrightness: 128)
                let after = current.whiteMask(in: region, minimumBrightness: 128)
                let ink = before.filter { $0 }.count
                #expect(ink > 100, "Exported avatar/header/footer must actually render, not disappear together")
                let unmatched = ChromePixels.unmatchedInk(before, after, rowWidth: Int(region.width), radius: 1)
                let difference = Double(unmatched) / Double(max(1, ink))
                if difference >= 0.2 {
                    try baseline.savePNG(to: fixture.folder.appendingPathComponent("baseline.png"))
                    try current.savePNG(to: fixture.folder.appendingPathComponent("step-\(step)-commit-\(commit).png"))
                    print("Post chrome native diagnostics: \(fixture.folder.path), region=\(region), delta=\(difference)")
                    fixture.keepsDiagnostics = true
                }
                #expect(difference < 0.2, "Post chrome must stay at the same pixels through paging and media-type changes")
            }
        }
    }

    @Test
    func partialSwipesKeepChromeStillUntilTheGroupBoundary() throws {
        let author = UUID(), place = UUID()
        let posts = (0..<3).map { _ in makePost(authorID: author, locationID: place) }
        let groups = PostPlaceGrouping.groups(posts, mode: .consecutive)
        for selected in posts {
            let run = try #require(PostPlaceChromeRun(groups: groups, selectedID: selected.id))
            for position in stride(from: CGFloat(0), through: 2, by: 0.125) {
                #expect(run.offset(position: position, width: 390) == 0)
            }
            #expect(run.offset(position: -0.4, width: 390) == 156)
            #expect(abs(run.offset(position: 2.4, width: 390) + 156) < 0.001)
        }
    }

    @Test
    func selectedPostKeepsItsOwnIdentityAndActualVerticalBounds() throws {
        let author = UUID(), place = UUID()
        let posts = (0..<3).map { _ in makePost(authorID: author, locationID: place) }
        let groups = PostPlaceGrouping.groups(posts, mode: .consecutive)
        let run = try #require(PostPlaceChromeRun(groups: groups, selectedID: posts[1].id))
        #expect(run.selectedID == posts[1].id)
        #expect(run.selectedIndex == 1)
        #expect(run.postIDs == posts.map(\.id))
        #expect(!run.contains(UUID()))
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 500)
        for displacement in [-156.0, 0, 156.0] {
            let frame = try #require(run.frame(
                pageFrame: CGRect(x: displacement, y: 22, width: 390, height: 478), viewport: viewport))
            #expect(frame == CGRect(x: 0, y: 22, width: 390, height: 478))
        }
    }

    @Test
    func anotherAuthorOrPlaceEndsTheRunAndSingletonsKeepOriginalChrome() throws {
        let author = UUID(), place = UUID()
        let first = makePost(authorID: author, locationID: place)
        let second = makePost(authorID: author, locationID: place)
        let otherAuthor = makePost(authorID: UUID(), locationID: place)
        let later = makePost(authorID: author, locationID: place)
        let groups = PostPlaceGrouping.groups([first, second, otherAuthor, later], mode: .consecutive)
        let run = try #require(PostPlaceChromeRun(groups: groups, selectedID: second.id))
        #expect(run.postIDs == [first.id, second.id])
        let frame = try #require(run.frame(pageFrame: CGRect(x: -156, y: 0, width: 390, height: 500),
                                          viewport: CGRect(x: 0, y: 0, width: 390, height: 500)))
        #expect(abs(frame.minX + 156) < 0.001)
        #expect(PostPlaceChromeRun(groups: groups, selectedID: otherAuthor.id) == nil)
        #expect(PostPlaceChromeRun(groups: groups, selectedID: later.id) == nil)
        #expect(PostPlaceChromeRun(groups: groups, selectedID: UUID()) == nil)
    }

    @Test
    func invalidMeasurementsNeverTranslateOrDrawChrome() throws {
        let author = UUID(), place = UUID()
        let posts = (0..<2).map { _ in makePost(authorID: author, locationID: place) }
        let run = try #require(PostPlaceChromeRun(
            groups: PostPlaceGrouping.groups(posts, mode: .aggregate), selectedID: posts[0].id))
        #expect(run.offset(position: .nan, width: 390) == 0)
        #expect(run.offset(position: 1, width: .infinity) == 0)
        #expect(run.offset(position: 1, width: 0) == 0)
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 500)
        #expect(run.frame(pageFrame: .zero, viewport: viewport) == nil)
        #expect(run.frame(pageFrame: viewport, viewport: .null) == nil)
    }

    @Test
    func photoAndVideoChromeShareTheSameTopAndBottomEdges() {
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 500)
        for source: CGSize in [CGSize(width: 36, height: 36), CGSize(width: 40, height: 40)] {
            #expect(PostPlaceChromeGeometry.frame(for: .avatar, sourceSize: source,
                viewport: viewport, horizontalOffset: 0, hasSeparateAvatar: true,
                footerHeight: 44) == CGRect(x: 18, y: 16, width: 36, height: 36))
        }
        for height: CGFloat in [22, 44] {
            let footer = PostPlaceChromeGeometry.frame(for: .footer,
                sourceSize: CGSize(width: 342, height: height), viewport: viewport,
                horizontalOffset: 0, hasSeparateAvatar: true, footerHeight: height)
            #expect(footer == CGRect(x: 64, y: 446, width: 308, height: 44))
        }
        for height: CGFloat in [20, 36] {
            let header = PostPlaceChromeGeometry.frame(for: .header,
                sourceSize: CGSize(width: 200, height: height), viewport: viewport,
                horizontalOffset: 0, hasSeparateAvatar: true, footerHeight: 44)
            #expect(header.minY == 16 && header.minX == 64)
        }
    }

    @Test
    func pageDotsCenterOnTheWholeCardWithoutMovingTheFooter() {
        for width: CGFloat in [320, 390, 430] {
            let viewport = CGRect(x: 12, y: 20, width: width, height: 500)
            for hasAvatar in [false, true] {
                for horizontalOffset: CGFloat in [-156, 0, 156] {
                    let footer = PostPlaceChromeGeometry.frame(for: .footer,
                        sourceSize: CGSize(width: 200, height: 44), viewport: viewport,
                        horizontalOffset: horizontalOffset, hasSeparateAvatar: hasAvatar,
                        footerHeight: 44, bottomSafeArea: 34)
                    let dotsOffset = PostPlaceChromeGeometry.pageDotsOffset(
                        footerFrame: footer, viewport: viewport, horizontalOffset: horizontalOffset)
                    #expect(footer.midX + dotsOffset == viewport.midX + horizontalOffset)
                    #expect(dotsOffset == (hasAvatar ? -23 : 0))
                    #expect(footer.minX == viewport.minX + horizontalOffset + (hasAvatar ? 64 : 18))
                    #expect(footer.maxY == viewport.maxY - 44)
                }
            }
        }
    }

    @Test
    func sharedFooterRespectsTheBottomSafeAreaAndBoundaryTranslation() {
        let frame = PostPlaceChromeGeometry.frame(for: .footer,
            sourceSize: CGSize(width: 200, height: 44),
            viewport: CGRect(x: 0, y: 0, width: 390, height: 500),
            horizontalOffset: -156, hasSeparateAvatar: true, footerHeight: 44,
            bottomSafeArea: 34)
        #expect(frame.minX == -92)
        #expect(frame.maxY == 456)
    }

    @Test
    func pagingStrideComesFromTheViewportNotAnInsetCardWidth() throws {
        let author = UUID(), place = UUID()
        let posts = (0..<2).map { _ in makePost(authorID: author, locationID: place) }
        let groups = PostPlaceGrouping.groups(posts, mode: .consecutive)
        let run = try #require(PostPlaceChromeRun(groups: groups, selectedID: posts[0].id))
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 500)

        // A full physical page has moved 390pt even if a nested measurement
        // has a narrower width. It must not overshoot by the media's inset.
        for measuredWidth: CGFloat in [362, 390] {
            let frame = try #require(run.frame(
                pageFrame: CGRect(x: -390, y: 0, width: measuredWidth, height: 500),
                viewport: viewport))
            #expect(frame == viewport)
        }
    }

    @Test
    func compactPhotoVideoSwipesAndReverseSettlingKeepEveryRoleStationary() throws {
        let author = UUID(), place = UUID()
        let posts = (0..<2).map { _ in makePost(authorID: author, locationID: place) }
        let groups = PostPlaceGrouping.groups(posts, mode: .consecutive)
        let pager = CGRect(x: 0, y: 0, width: 390, height: 500)

        for selectedIndex in posts.indices {
            let run = try #require(PostPlaceChromeRun(groups: groups, selectedID: posts[selectedIndex].id))
            for position in stride(from: CGFloat(0), through: 1, by: 0.125) {
                let fullPage = CGRect(x: (CGFloat(selectedIndex) - position) * 390,
                                      y: 0, width: 390, height: 500)
                let pinnedPage = try #require(run.frame(pageFrame: fullPage, viewport: pager))
                let compact = PostPlaceChromeGeometry.viewport(for: pinnedPage, in: pager)
                #expect(compact == pager)
                for role: PostPlaceChromeRole in [.avatar, .header, .footer, .capsule] {
                    let size = CGSize(width: 36, height: 36)
                    let actual = PostPlaceChromeGeometry.frame(for: role, sourceSize: size,
                        viewport: compact, horizontalOffset: pinnedPage.minX,
                        hasSeparateAvatar: true, footerHeight: 44)
                    let expected = PostPlaceChromeGeometry.frame(for: role, sourceSize: size,
                        viewport: pager, horizontalOffset: 0,
                        hasSeparateAvatar: true, footerHeight: 44)
                    #expect(actual == expected)
                }
            }
        }

        // The existing video's inset remains a card detail, not compact
        // chrome's coordinate system. Expanded content still may use it.
        let insetVideoCard = CGRect(x: 12, y: 12, width: 366, height: 488)
        #expect(PostPlaceChromeGeometry.viewport(for: pager, in: pager) == pager)
        #expect(PostPlaceChromeGeometry.viewport(for: pager, in: pager,
            cardFrame: insetVideoCard) == CGRect(x: 0, y: 12, width: 390, height: 488))
    }

    @Test
    func missingSelectedPageUsesOneVisibleSiblingForGeometryAndAllParts() throws {
        let author = UUID(), place = UUID()
        let posts = (0..<3).map { _ in makePost(authorID: author, locationID: place) }
        let groups = PostPlaceGrouping.groups(posts, mode: .consecutive)
        let run = try #require(PostPlaceChromeRun(groups: groups, selectedID: posts[0].id))
        let pager = CGRect(x: 0, y: 0, width: 390, height: 500)
        let pages = [posts[1].id: CGRect(x: -78, y: 0, width: 390, height: 500),
                     posts[2].id: CGRect(x: 312, y: 0, width: 390, height: 500)]
        let source = try #require(run.sourceID(pageFrames: pages,
            availableParts: Set(posts.map(\.id)), viewport: pager))
        #expect(source == posts[1].id)
        #expect(run.frame(pageFrame: try #require(pages[source]), viewport: pager, sourceID: source) == pager)
        #expect(run.sourceID(pageFrames: pages, availableParts: [], viewport: pager) == nil)

        // A remaining selected frame without its role views is not a valid
        // source. Conversely, a mounted selected Post retains action identity.
        var withSelected = pages
        withSelected[posts[0].id] = CGRect(x: -468, y: 0, width: 390, height: 500)
        #expect(run.sourceID(pageFrames: withSelected, availableParts: [posts[1].id],
            viewport: pager) == posts[1].id)
        #expect(run.sourceID(pageFrames: withSelected, availableParts: [posts[0].id, posts[1].id],
            viewport: pager) == posts[0].id)

        let unrelated = UUID()
        #expect(run.sourceID(pageFrames: [unrelated: pager], availableParts: [unrelated],
            viewport: pager) == nil)
    }

    @Test
    func incomingGroupUsesTheSameFrameBeforeAndAfterSelectionCommits() throws {
        let author = UUID(), place = UUID()
        let posts = (0..<2).map { _ in makePost(authorID: author, locationID: place) }
        let groups = PostPlaceGrouping.groups(posts, mode: .consecutive)
        let pending = try #require(PostPlaceChromeRun(groups: groups, selectedID: posts[0].id))
        let settled = try #require(PostPlaceChromeRun(groups: groups, selectedID: posts[1].id))
        let pager = CGRect(x: 0, y: 0, width: 390, height: 500)
        let incoming = CGRect(x: 156, y: 0, width: 390, height: 500)
        #expect(pending.frame(pageFrame: incoming, viewport: pager) == incoming)

        // At the second member's resting offset, a retained first member and
        // the newly selected second member resolve exactly the same shell.
        let pages = [posts[0].id: CGRect(x: -390, y: 0, width: 390, height: 500),
                     posts[1].id: pager]
        let parts = Set(posts.map(\.id))
        let beforeID = try #require(pending.sourceID(pageFrames: pages, availableParts: parts, viewport: pager))
        let afterID = try #require(settled.sourceID(pageFrames: pages, availableParts: parts, viewport: pager))
        #expect(beforeID == posts[0].id && afterID == posts[1].id)
        #expect(pending.frame(pageFrame: try #require(pages[beforeID]), viewport: pager,
            sourceID: beforeID) == settled.frame(pageFrame: try #require(pages[afterID]), viewport: pager,
            sourceID: afterID))
        #expect(pending.id == settled.id)
        #expect(pending.postIDs == settled.postIDs)
    }

    @Test
    func reverseEntryUsesTheVisibleLastMemberNotTheGroupsFirstMember() throws {
        let author = UUID(), place = UUID()
        let posts = (0..<3).map { _ in makePost(authorID: author, locationID: place) }
        let run = try #require(PostPlaceChromeRun(groups:
            PostPlaceGrouping.groups(posts, mode: .consecutive), selectedID: posts[0].id))
        let pager = CGRect(x: 0, y: 0, width: 390, height: 500)
        let pages = Dictionary(uniqueKeysWithValues: posts.enumerated().map { index, post in
            (post.id, CGRect(x: CGFloat(index - 2) * 390 - 156,
                             y: 0, width: 390, height: 500))
        })
        let source = try #require(run.sourceID(pageFrames: pages, availableParts: Set(posts.map(\.id)),
            viewport: pager, prefersSelected: false))
        #expect(source == posts[2].id)
        let sourceFrame = try #require(pages[source])
        let frame = try #require(run.frame(pageFrame: sourceFrame,
            viewport: pager, sourceID: source))
        #expect(abs(frame.minX + 156) < 0.001)

        // Lazy pages outside the viewport cannot produce a floating ghost
        // shell after the group has entirely left the screen.
        let departed = pages.mapValues { $0.offsetBy(dx: -390, dy: 0) }
        #expect(run.sourceID(pageFrames: departed, availableParts: Set(posts.map(\.id)),
            viewport: pager, prefersSelected: false) == nil)
    }

    @Test
    func expandedChromeScrollsVerticallyWithItsCardInsteadOfCoveringDiscussion() {
        let pagerViewport = CGRect(x: 0, y: 0, width: 390, height: 800)
        let fullPage = CGRect(x: -156, y: 0, width: 390, height: 800)
        let originalCard = CGRect(x: -144, y: 20, width: 366, height: 420)
        let scrolledCard = originalCard.offsetBy(dx: 0, dy: -260)
        let originalViewport = PostPlaceChromeGeometry.viewport(for: fullPage, in: pagerViewport,
            cardFrame: originalCard)
        let scrolledViewport = PostPlaceChromeGeometry.viewport(for: fullPage, in: pagerViewport,
            cardFrame: scrolledCard)
        #expect(originalViewport.minX == 0 && scrolledViewport.minX == 0)
        #expect(originalViewport.width == 390 && scrolledViewport.width == 390)
        #expect(originalViewport.height == 420 && scrolledViewport.height == 420)
        for role: PostPlaceChromeRole in [.avatar, .header, .footer, .capsule] {
            let sourceSize = CGSize(width: 36, height: 36)
            let original = PostPlaceChromeGeometry.frame(for: role, sourceSize: sourceSize,
                viewport: originalViewport, horizontalOffset: 0, hasSeparateAvatar: true, footerHeight: 44)
            let scrolled = PostPlaceChromeGeometry.frame(for: role, sourceSize: sourceSize,
                viewport: scrolledViewport, horizontalOffset: 0, hasSeparateAvatar: true, footerHeight: 44)
            #expect(scrolled.minX == original.minX)
            #expect(scrolled.minY == original.minY - 260)
            #expect(scrolled.maxY <= scrolledCard.maxY)
        }
    }

    private func makePost(authorID: UUID, locationID: UUID) -> RealPost {
        RealPost(id: UUID(), userId: authorID,
                 center: .init(latitude: 47.6062, longitude: -122.3321), radiusMeters: 40,
                 message: "Individual Post", attachments: [], likes: [], comments: [],
                 visibility: .publicAll, createdAt: Date(timeIntervalSince1970: 100),
                 expiresAt: Date(timeIntervalSince1970: 200), locationID: locationID)
    }
}

@MainActor
private final class PostChromeHostingState: ObservableObject {
    @Published var selection: UUID
    init(_ selection: UUID) { self.selection = selection }
}

private struct PostChromeHostingView: View {
    let posts: [RealPost]
    let user: User
    let motion: ProfileCardSheetMotion
    @ObservedObject var state: PostChromeHostingState
    var body: some View {
        let items = posts.map { ExperienceDetailView.SequencePager.Item(id: $0.id, mode: .real($0, user)) }
        ProfileSequencePager(items: items, selection: $state.selection, isExpanded: false,
            motion: motion, usesFixedCompactCanvas: true, background: { _ in PostCardPalette.black.background }) { item in
                ExperienceDetailView(mode: item.mode, isExpanded: false, usesClassicPostPreview: true)
            }
            .fixedPostPlaceChrome(groups: PostPlaceGrouping.groups(posts, mode: .consecutive),
                                  selectedID: state.selection, isExpanded: false)
            .environment(\.friendStoryPlaybackEnabled, false)
            .environment(\.postCardPalette, .black)
            .environment(\.postSheetDesign, .refined)
            .environment(\.colorScheme, .dark)
    }
}

@MainActor
private final class PostChromeHostingFixture {
    let folder: URL
    let posts: [RealPost]
    let state: PostChromeHostingState
    let host: UIHostingController<AnyView>
    let window: UIWindow
    var keepsDiagnostics = false

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("post-chrome-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = folder.appendingPathComponent("dark.png")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let data = try #require(image.pngData())
        try data.write(to: photo)
        let user = User(id: UUID(), handle: "Fixed author", avatarURL: nil)
        let place = UUID(), date = Date().addingTimeInterval(-120)
        let kinds: [RealPost.Attachment.Kind] = [.photo(photo),
            .video(url: folder.appendingPathComponent("inactive.mp4"), poster: photo)]
        posts = kinds.map { kind in RealPost(id: UUID(), userId: user.id,
            center: .init(latitude: 47.6, longitude: -122.3), radiusMeters: 40,
            message: nil, attachments: [.init(kind: kind)], likes: [], comments: [],
            visibility: .privateOnly, createdAt: date, expiresAt: date.addingTimeInterval(86400), locationID: place) }
        state = PostChromeHostingState(posts[0].id)
        let motion = ProfileCardSheetMotion()
        motion.setCompactFraction(ProfileCardPagingLayout.postFraction)
        motion.reportGeometry(maximumHeight: 500 / ProfileCardPagingLayout.postFraction,
                              bottom: 0, allowsUpdates: { true })
        host = UIHostingController(rootView: AnyView(PostChromeHostingView(posts: posts, user: user,
            motion: motion, state: state).frame(width: 390, height: 500).ignoresSafeArea()))
        host.safeAreaRegions = []
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        let root = UIViewController()
        window.rootViewController = root
        root.loadViewIfNeeded()
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 500)
        window.isHidden = false
    }

    func settle() async throws {
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.view.layoutIfNeeded()
    }

    func horizontalPager() -> UIScrollView? {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(host.view).compactMap { $0 as? UIScrollView }.first {
            $0.bounds.width > 300 && $0.contentSize.width > $0.bounds.width * 1.5
        }
    }

    func pixels() throws -> ChromePixels {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let cg = try #require(image.cgImage)
        var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return ChromePixels(width: cg.width, height: cg.height, rgba: rgba, cgImage: cg)
    }

    func dispose() {
        window.isHidden = true; window.rootViewController = nil
        if !keepsDiagnostics { try? FileManager.default.removeItem(at: folder) }
    }
}
