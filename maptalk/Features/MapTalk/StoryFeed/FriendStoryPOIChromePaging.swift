import SwiftUI

/// Every POI visit canvas shares place information with matching adjacent
/// pages, including location-only visits and media that has not loaded yet.
struct FriendStoryPOIChromePage {
    let id: String
    let place: RatedPOI?
    var authorID: UUID? = nil
    var visitDayKey: String? = nil

    static func storyPage(_ page: FriendStoryPage) -> Self {
        let place: RatedPOI?
        if case let .poi(rated, _, _) = page.content { place = rated }
        else { place = nil }
        return .init(id: page.id, place: place, authorID: page.authorID,
                     visitDayKey: page.poiVisitDayKey)
    }

    func sharesStop(with other: Self) -> Bool {
        guard let place, other.place?.id == place.id else { return false }
        return authorID == other.authorID && visitDayKey == other.visitDayKey
    }
}

struct FriendStoryPOIChromeRun {
    let place: RatedPOI
    let selectedID: String
    let selectedIndex: Int
    let range: ClosedRange<Int>
    let pageIDs: [String]

    var id: String { pageIDs[0] }

    init?(pages: [FriendStoryPOIChromePage], selectedID: String) {
        guard let selected = pages.firstIndex(where: { $0.id == selectedID }),
              let place = pages[selected].place else { return nil }
        var lower = selected
        var upper = selected
        while lower > 0, pages[lower - 1].sharesStop(with: pages[selected]) { lower -= 1 }
        while upper + 1 < pages.count, pages[upper + 1].sharesStop(with: pages[selected]) { upper += 1 }
        self.place = place
        self.selectedID = selectedID
        self.selectedIndex = selected
        self.range = lower...upper
        self.pageIDs = pages[lower...upper].map(\.id)
    }

    func contains(_ id: String) -> Bool { pageIDs.contains(id) }

    /// Inside one place the chrome stays at zero. Only crossing the boundary
    /// slides it away, alongside the final/first page of that place.
    func offset(position: CGFloat, width: CGFloat) -> CGFloat {
        guard position.isFinite, width.isFinite, width > 0 else { return 0 }
        let pinnedPosition = min(max(position, CGFloat(range.lowerBound)), CGFloat(range.upperBound))
        return (pinnedPosition - position) * width
    }

    /// Native TabView and the mixed-height ScrollView both supply media bounds
    /// in the surrounding viewport. Derive progress from those actual bounds;
    /// no second scroll cursor or per-frame model publication is needed.
    func frame(pageFrames: [String: CGRect], viewport: CGRect) -> CGRect? {
        guard Self.isUsable(viewport) else { return nil }
        let anchorID: String
        if let selectedFrame = pageFrames[selectedID], Self.isUsable(selectedFrame) {
            anchorID = selectedID
        } else if let visible = pageIDs.first(where: { id in
            guard let frame = pageFrames[id], Self.isUsable(frame) else { return false }
            return frame.maxX > viewport.minX && frame.minX < viewport.maxX
        }) {
            // Lazy paging may not have mounted the selected page yet. A
            // visible sibling gives the same position within this run.
            anchorID = visible
        } else {
            return nil
        }
        guard let anchor = pageFrames[anchorID],
              let indexInRun = pageIDs.firstIndex(of: anchorID) else { return nil }
        let index = range.lowerBound + indexInRun
        let position = CGFloat(index) - (anchor.minX - viewport.minX) / anchor.width
        return CGRect(
            x: viewport.minX + offset(position: position, width: anchor.width),
            y: anchor.minY,
            width: anchor.width,
            height: anchor.height
        )
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        !frame.isNull && frame.minX.isFinite && frame.minY.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}

private struct FriendStoryPOIChromeAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct FriendStoryFixedPOIChrome: ViewModifier {
    let pages: [FriendStoryPOIChromePage]
    let selectedID: String
    let showsPageDots: Bool
    let playbackFooter: AnyView?

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(FriendStoryPOIChromeAnchors.self) { anchors in
            GeometryReader { geometry in
                if let run = FriendStoryPOIChromeRun(pages: pages, selectedID: selectedID),
                   let frame = run.frame(
                    pageFrames: anchors.mapValues { geometry[$0] },
                    viewport: CGRect(origin: .zero, size: geometry.size)) {
                    FriendStoryPOIChrome(place: run.place)
                        .overlay(alignment: .bottom) {
                            if let playbackFooter {
                                playbackFooter
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 12)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if showsPageDots {
                                FriendStoryPlacePageDots(count: run.range.count,
                                    index: run.selectedIndex - run.range.lowerBound)
                                    .padding(.bottom, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                        .environment(\.colorScheme, .dark)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .id(run.id)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("friend-story.poi.fixed-chrome")
                }
            }
            .clipped()
        }
    }
}

extension View {
    func poiChromePageAnchor(id: String?) -> some View {
        anchorPreference(key: FriendStoryPOIChromeAnchors.self, value: .bounds) { anchor in
            guard let id else { return [:] }
            return [id: anchor]
        }
    }

    func fixedPOIChrome(pages: [FriendStoryPOIChromePage], selectedID: String,
                        showsPageDots: Bool = false, playbackFooter: AnyView? = nil) -> some View {
        modifier(FriendStoryFixedPOIChrome(pages: pages, selectedID: selectedID,
                                          showsPageDots: showsPageDots, playbackFooter: playbackFooter))
    }
}
