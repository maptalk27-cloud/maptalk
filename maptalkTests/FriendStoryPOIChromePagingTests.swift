import Combine
import CoreLocation
import SwiftUI
import Testing
import UIKit
@testable import maptalk

/// A settled-page assertion alone cannot catch chrome that slides away and
/// returns. These render the actual Home/Bubble pagers at a partial offset.
@MainActor
@Suite(.serialized)
struct FriendStoryPOIChromePagingTests {
    @Test
    func onePlaceKeepsChromeStillAcrossItsWholePhotoAndVideoRun() throws {
        let data = try POIChromeFixtureData()
        defer { data.dispose() }
        let pages = [
            FriendStoryPOIChromePage(id: "post-before", place: nil),
            .init(id: "photo", place: data.place),
            .init(id: "video", place: data.place),
            .init(id: "next-visit", place: data.place),
            .init(id: "other-place", place: data.otherPlace),
            .init(id: "post-after", place: nil),
            .init(id: "same-place-later", place: data.place)
        ]
        for selected in ["photo", "video", "next-visit"] {
            let run = try #require(FriendStoryPOIChromeRun(pages: pages, selectedID: selected))
            #expect(run.range == 1...3)
            #expect(run.place.id == data.place.id)
            #expect(run.contains("photo") && run.contains("video") && run.contains("next-visit"))
            #expect(!run.contains("other-place") && !run.contains("same-place-later"))
            for position in stride(from: CGFloat(1), through: 3, by: 0.125) {
                #expect(run.offset(position: position, width: 390) == 0,
                        "Changing a media page or visit at the same place never translates its chrome")
            }
            #expect(run.offset(position: 0.5, width: 390) == 195)
            #expect(run.offset(position: 3.5, width: 390) == -195)
        }
        #expect(FriendStoryPOIChromeRun(pages: pages, selectedID: "post-before") == nil)
        #expect(FriendStoryPOIChromeRun(pages: pages, selectedID: "post-after") == nil)
        #expect(FriendStoryPOIChromeRun(pages: pages, selectedID: "missing") == nil)
        let repeated = try #require(FriendStoryPOIChromeRun(pages: pages, selectedID: "same-place-later"))
        #expect(repeated.range == 6...6, "A later visit separated by a Post is not the current visible run")
    }

    @Test
    func fixedChromeUsesTheVisibleMediaCanvasAndDoesNotCoverAnotherCard() throws {
        let data = try POIChromeFixtureData()
        defer { data.dispose() }
        let pages = [FriendStoryPOIChromePage(id: "first", place: data.place),
                     .init(id: "second", place: data.place), .init(id: "post", place: nil)]
        let run = try #require(FriendStoryPOIChromeRun(pages: pages, selectedID: "first"))
        let viewport = CGRect(x: 0, y: 0, width: 390, height: 330)
        let during = try #require(run.frame(pageFrames: [
            "first": CGRect(x: -195, y: 22, width: 390, height: 308),
            "second": CGRect(x: 195, y: 22, width: 390, height: 308)
        ], viewport: viewport))
        #expect(during.minX == 0)
        #expect(during.minY == 22 && during.height == 308,
                "The fixed overlay must use the media's actual safe-area canvas, not its outer sheet")
        #expect(run.frame(pageFrames: [:], viewport: viewport) == nil)
        #expect(FriendStoryPOIChromeRun(pages: pages, selectedID: "post") == nil)
    }

    @Test(arguments: [POIChromeTestSurface.homeCompact, .bubbleCompact, .bubbleExpanded])
    func actualPagersKeepHeadingAndStatsFixedDuringPartialSwipeAndCancel(surface: POIChromeTestSurface) async throws {
        let data = try POIChromeFixtureData()
        defer { data.dispose() }
        let fixture = try POIChromeHostingFixture(data: data, surface: surface)
        defer { fixture.dispose() }
        try await fixture.settle()
        let pager = try #require(fixture.horizontalPager(), "The test must drive the real native media pager")
        let baseline = try fixture.pixels()
        let start = pager.contentOffset
        let displacement = pager.bounds.width * 0.4
        try #require(displacement > 100)
        pager.setContentOffset(CGPoint(x: start.x + displacement, y: start.y), animated: false)
        try await fixture.settle(milliseconds: 100)
        #expect(abs(pager.contentOffset.x - start.x) > pager.bounds.width * 0.25,
                "A no-op scroll would produce a false-positive stationary-chrome test")
        let during = try fixture.pixels()
        expectStationaryChrome(baseline, during, height: fixture.height)

        pager.setContentOffset(start, animated: false)
        try await fixture.settle(milliseconds: 100)
        let cancelled = try fixture.pixels()
        expectStationaryChrome(baseline, cancelled, height: fixture.height)
    }

    @Test
    func actualBubbleChromeSlidesAwayOnlyAfterTheLastPageOfItsPlace() async throws {
        let data = try POIChromeFixtureData()
        defer { data.dispose() }
        let fixture = try POIChromeHostingFixture(data: data, surface: .bubbleExpanded)
        defer { fixture.dispose() }
        try await fixture.settle()
        let pager = try #require(fixture.horizontalPager())
        let baseline = try fixture.pixels()
        let start = pager.contentOffset
        let width = pager.bounds.width
        let shift = (width * 0.4).rounded()
        // Three media pages belong to the same POI. At 2.4 the last page is
        // leaving and another place is entering; the old chrome must leave too.
        let target = start.x + 2 * width + shift
        pager.setContentOffset(CGPoint(x: target, y: start.y), animated: false)
        try await fixture.settle(milliseconds: 150)
        #expect(abs(pager.contentOffset.x - target) < 2,
                "This must exercise the native pager beyond the current place's final page")
        #expect(fixture.state.memberID == data.place.id,
                "Do not let a selection update disguise an anchor that failed to track the swipe")
        let during = try fixture.pixels()
        // Exclude the incoming card entirely. The outgoing visible glyphs
        // must match the original glyphs shifted left by exactly 40% width.
        let outgoingWidth = width - shift - 4
        let regions = [CGRect(x: 0, y: 20, width: outgoingWidth, height: 115),
                       CGRect(x: 0, y: CGFloat(fixture.height - 90), width: outgoingWidth, height: 64)]
        var unshiftedDifference = 0
        var visibleInk = 0
        for (index, region) in regions.enumerated() {
            let expected = baseline.whiteMask(in: region.offsetBy(dx: shift, dy: 0))
            let actual = during.whiteMask(in: region)
            let unshifted = baseline.whiteMask(in: region)
            let ink = expected.filter { $0 }.count
            #expect(ink > 15, "The boundary comparison needs visible outgoing labels/actions")
            let incorrectPixels = zip(expected, actual).filter { $0.0 != $0.1 }.count
            // Native scrolling is rendered at the device's fractional-pixel scale,
            // then sampled into a 1x snapshot. Allow one pixel of glyph-edge AA,
            // in both directions, without permitting missing or additional labels.
            let unmatchedPixels = ChromePixels.unmatchedInk(expected, actual,
                rowWidth: Int(region.maxX) - Int(region.minX), radius: 1)
            let exactRatio = Double(incorrectPixels) / Double(max(ink, 1))
            let unmatchedRatio = Double(unmatchedPixels) / Double(max(ink, 1))
            if unmatchedRatio >= 0.12 {
                print("POI chrome boundary offset: width=\(width), target=\(target), actual=\(pager.contentOffset.x), shift=\(shift)")
                print("POI chrome boundary region \(index): ink=\(ink), exact=\(incorrectPixels) (\(exactRatio)), unmatched±1px=\(unmatchedPixels) (\(unmatchedRatio))")
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("poi-chrome-boundary-diagnostics")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try baseline.savePNG(to: folder.appendingPathComponent("baseline.png"))
                try during.savePNG(to: folder.appendingPathComponent("during.png"))
                try baseline.savePNG(to: folder.appendingPathComponent("expected-\(index).png"),
                                     crop: region.offsetBy(dx: shift, dy: 0))
                try during.savePNG(to: folder.appendingPathComponent("actual-\(index).png"), crop: region)
                print("POI chrome boundary screenshots: \(folder.path)")
            }
            #expect(unmatchedRatio < 0.12,
                    "At a place boundary the original chrome must follow its outgoing card, not cover the next card")
            visibleInk += ink
            unshiftedDifference += zip(unshifted, actual).filter { $0.0 != $0.1 }.count
        }
        #expect(Double(unshiftedDifference) / Double(max(visibleInk, 1)) > 0.5,
                "A permanently stationary overlay must fail the boundary test")
    }

    @Test
    func bubblePhotoVideoPagesKeepOnePlaceWhilePostHasNoPlaceChrome() throws {
        let data = try POIChromeFixtureData()
        defer { data.dispose() }
        let pages = HomeBubblePage.pages(in: data.scope)
        let own = pages.filter { $0.memberID == data.place.id }
        #expect(own.count == 3)
        #expect(Set(own.map(\.id)).count == 3)
        #expect(own.filter { if case .photo? = $0.media?.kind { return true }; return false }.count == 2)
        #expect(own.filter { if case .video? = $0.media?.kind { return true }; return false }.count == 1)
        let descriptors = pages.map { page in
            FriendStoryPOIChromePage(id: page.id.uuidString,
                place: { if case let .poi(place) = page.mode, page.media != nil { return place }; return nil }())
        }
        for page in own {
            #expect(FriendStoryPOIChromeRun(pages: descriptors, selectedID: page.id.uuidString)?.place.id == data.place.id)
        }
        let postPage = try #require(pages.first { $0.memberID == data.post.id })
        #expect(FriendStoryPOIChromeRun(pages: descriptors, selectedID: postPage.id.uuidString) == nil)
    }

    private func expectStationaryChrome(_ before: ChromePixels, _ after: ChromePixels, height: Int,
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        // Local fixture photos and video posters are identical dark gray.
        // Compare only bright neutral glyphs, not media playback or shadows.
        let regions = [CGRect(x: 12, y: 20, width: 366, height: 115),
                       CGRect(x: 140, y: height - 90, width: 238, height: 64)]
        for region in regions {
            let original = before.whiteMask(in: region)
            let current = after.whiteMask(in: region)
            let ink = original.filter { $0 }.count
            #expect(ink > 15, "The snapshot must actually contain the heading/statistics", sourceLocation: sourceLocation)
            let changed = zip(original, current).filter { $0.0 != $0.1 }.count
            #expect(Double(changed) / Double(max(ink, 1)) < 0.12,
                    "POI labels and actions must not translate with the photo/video page", sourceLocation: sourceLocation)
        }
    }
}

enum POIChromeTestSurface: String, CaseIterable {
    case homeCompact, bubbleCompact, bubbleExpanded
}

@MainActor
private final class POIChromeFixtureData {
    let folder: URL
    let userID = UUID()
    let place: RatedPOI
    let otherPlace: RatedPOI
    let post: RealPost
    let group: FriendStoryGroup
    let scope: MapJourneyScope

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("poi-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photoURL = folder.appendingPathComponent("gray.png")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let gray = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        try #require(gray.pngData()).write(to: photoURL)
        let media: [RatedPOI.Media] = [
            .init(kind: .photo(photoURL)),
            .init(kind: .video(url: folder.appendingPathComponent("inactive-test-video.mp4"), poster: photoURL)),
            .init(kind: .photo(photoURL))
        ]
        let now = Date()
        let visit = RatedPOI.CheckIn(userId: userID, createdAt: now.addingTimeInterval(-60),
                                    endorsement: .hype, media: media, tag: .explore)
        place = Self.place(name: "Fixed place", visit: visit)
        otherPlace = Self.place(name: "Another place", visit: .init(userId: userID,
            createdAt: now.addingTimeInterval(-30), media: [.init(kind: .photo(photoURL))]))
        post = RealPost(id: UUID(), userId: userID, center: place.poi.coordinate, radiusMeters: 100,
            message: "A separate Post", attachments: [], likes: [], comments: [], visibility: .publicAll,
            createdAt: now.addingTimeInterval(-10), expiresAt: now.addingTimeInterval(86_400))
        group = try #require(FriendStoryFeed.groups(reals: [], ratedPOIs: [place],
            userProvider: { _ in nil }, now: now).first)
        let journey = JourneyPost(id: UUID(), userId: userID, title: "Fixed chrome test", content: "",
            coordinate: place.poi.coordinate, createdAt: now,
            orderedMemberReferences: [.poi(place.id), .poi(otherPlace.id), .reel(post.id)],
            reels: [post], pois: [place, otherPlace], likes: [], comments: [])
        scope = MapJourneyScope(journey: journey, userProvider: { _ in nil })
    }

    func dispose() { try? FileManager.default.removeItem(at: folder) }

    private static func place(name: String, visit: RatedPOI.CheckIn) -> RatedPOI {
        .init(poi: .init(id: UUID(), name: name, coordinate: .init(latitude: 47.6, longitude: -122.3),
                        category: .viewpoint),
              media: visit.media, checkIns: [visit], comments: [],
              endorsements: .init(hype: 3, solid: 2, meh: 0, questionable: 0), tags: [],
              isFavoritedByCurrentUser: false, favoritesCount: 8)
    }
}

@MainActor
private final class POIChromeHostingFixture {
    let window: UIWindow
    let host: UIHostingController<AnyView>
    let height: Int
    let motion = ProfileCardSheetMotion()
    let state: POIChromeHostingState

    init(data: POIChromeFixtureData, surface: POIChromeTestSurface) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        height = surface == .bubbleExpanded ? 620 : 330
        state = POIChromeHostingState(pageID: data.group.pages[0].id, memberID: data.place.id)
        let content = POIChromeHostingView(data: data, state: state, surface: surface)
            .environment(\.profileCardSheetMotion, motion)
            .environment(\.scenePhase, .active)
            .environment(\.colorScheme, .dark)
            .frame(width: 390, height: CGFloat(height))
            .ignoresSafeArea()
        host = UIHostingController(rootView: AnyView(content))
        host.safeAreaRegions = []
        window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        let root = UIViewController()
        window.rootViewController = root
        root.loadViewIfNeeded()
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: CGFloat(height))
        window.isHidden = false
        motion.reportGeometry(maximumHeight: 330 / ProfileCardPagingLayout.poiFraction,
                              bottom: 0, allowsUpdates: { true })
    }

    func settle(milliseconds: Int = 250) async throws {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(milliseconds))
        host.view.layoutIfNeeded()
    }

    func horizontalPager() -> UIScrollView? {
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(descendants)
        }
        return descendants(host.view).compactMap { $0 as? UIScrollView }.first {
            $0.bounds.width > 300 && $0.contentSize.width > $0.bounds.width * 1.5
        }
    }

    func pixels() throws -> ChromePixels {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return ChromePixels(width: width, height: height, rgba: rgba, cgImage: cgImage)
    }

    func dispose() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

@MainActor
private final class POIChromeHostingState: ObservableObject {
    @Published var pageID: String
    @Published var memberID: UUID?
    init(pageID: String, memberID: UUID) {
        self.pageID = pageID
        self.memberID = memberID
    }
}

private struct POIChromeHostingView: View {
    let data: POIChromeFixtureData
    @ObservedObject var state: POIChromeHostingState
    let surface: POIChromeTestSurface

    var body: some View {
        if surface == .homeCompact {
            let page = data.group.pages.first { $0.id == state.pageID } ?? data.group.pages[0]
            FriendStoryContentView(group: data.group, page: page,
                pageIndex: data.group.pages.firstIndex { $0.id == page.id } ?? 0,
                pagerPages: data.group.pages, pagerUserProvider: { _ in nil },
                selectedPageID: $state.pageID, viewedKeys: [], isExpanded: false, isPlaybackActive: false,
                onPreviousPage: {}, onNextPage: {}, onSelectPage: { _ in }, onExpand: {}, onClose: {},
                onJourney: { _, _ in }, onReadReady: { _ in }, journeyProvider: { _ in nil },
                userProvider: { _ in nil }, placeProvider: { _ in nil })
        } else {
            HomeBubbleContentView(scope: data.scope, selection: $state.memberID,
                isExpanded: surface == .bubbleExpanded, isActive: false,
                onExpand: {}, onBack: {}, onClose: {}, onJourney: { _ in },
                journeyProvider: { _ in nil }, userProvider: { _ in nil }, onRead: { _ in }, viewedKeys: [])
        }
    }
}

private struct ChromePixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]
    let cgImage: CGImage

    @MainActor
    func savePNG(to url: URL, crop: CGRect? = nil) throws {
        let image: CGImage
        if let crop { image = try #require(cgImage.cropping(to: crop)) }
        else { image = cgImage }
        try #require(UIImage(cgImage: image).pngData()).write(to: url)
    }

    static func unmatchedInk(_ first: [Bool], _ second: [Bool], rowWidth: Int, radius: Int) -> Int {
        guard rowWidth > 0, first.count == second.count, first.count % rowWidth == 0 else {
            return max(first.count, second.count)
        }
        let rows = first.count / rowWidth
        func unmatched(_ source: [Bool], _ target: [Bool]) -> Int {
            source.indices.filter { index in
                guard source[index] else { return false }
                let x = index % rowWidth, y = index / rowWidth
                for nearbyY in max(0, y - radius)...min(rows - 1, y + radius) {
                    for nearbyX in max(0, x - radius)...min(rowWidth - 1, x + radius) {
                        if target[nearbyY * rowWidth + nearbyX] { return false }
                    }
                }
                return true
            }.count
        }
        return unmatched(first, second) + unmatched(second, first)
    }

    func whiteMask(in rect: CGRect) -> [Bool] {
        let left = max(0, Int(rect.minX)), right = min(width, Int(rect.maxX))
        let top = max(0, Int(rect.minY)), bottom = min(height, Int(rect.maxY))
        guard left < right, top < bottom else { return [] }
        return (top..<bottom).flatMap { y in
            (left..<right).map { x in
                let offset = (y * width + x) * 4
                let red = Int(rgba[offset]), green = Int(rgba[offset + 1]), blue = Int(rgba[offset + 2])
                return min(red, green, blue) > 180 && max(red, green, blue) - min(red, green, blue) < 45
            }
        }
    }
}
