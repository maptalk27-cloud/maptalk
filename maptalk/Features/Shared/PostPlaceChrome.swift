import SwiftUI

/// The current author's contiguous place group in a flattened Post pager.
/// Horizontal coordinates come from full pager pages, never inset media cards.
struct PostPlaceChromeRun: Identifiable {
    let id: String
    let postIDs: [UUID]
    let selectedID: UUID
    let selectedIndex: Int

    init?(groups: [PostPlaceGroup], selectedID: UUID) {
        guard let group = groups.first(where: { $0.posts.contains { $0.id == selectedID } }),
              group.posts.count > 1,
              let index = group.posts.firstIndex(where: { $0.id == selectedID }) else { return nil }
        self.id = group.id
        self.postIDs = group.posts.map(\.id)
        self.selectedID = selectedID
        self.selectedIndex = index
    }

    func contains(_ postID: UUID) -> Bool { postIDs.contains(postID) }

    /// Stay put between members of this group, but leave with the last/first
    /// member when the user crosses to another author or place.
    func offset(position: CGFloat, width: CGFloat) -> CGFloat {
        guard position.isFinite, width.isFinite, width > 0 else { return 0 }
        let pinned = min(max(position, 0), CGFloat(postIDs.count - 1))
        return (pinned - position) * width
    }

    func sourceID(pageFrames: [UUID: CGRect], availableParts: Set<UUID>, viewport: CGRect,
                  prefersSelected: Bool = true) -> UUID? {
        guard Self.isUsable(viewport), postIDs.contains(where: { id in
            guard let frame = pageFrames[id], Self.isUsable(frame) else { return false }
            return frame.maxX > viewport.minX && frame.minX < viewport.maxX
        }) else { return nil }
        // Keep the selected Post's actions until paging commits. If lazy paging
        // removes it, use one visible sibling for ALL roles, never mixed IDs.
        if prefersSelected, let frame = pageFrames[selectedID], Self.isUsable(frame), availableParts.contains(selectedID) {
            return selectedID
        }
        return postIDs.compactMap { id -> (id: UUID, distance: CGFloat)? in
            guard let frame = pageFrames[id], Self.isUsable(frame), availableParts.contains(id),
                  frame.maxX > viewport.minX, frame.minX < viewport.maxX else { return nil }
            return (id, abs(frame.midX - viewport.midX))
        }.min { $0.distance < $1.distance }?.id
    }

    func frame(pageFrame: CGRect, viewport: CGRect, sourceID: UUID? = nil) -> CGRect? {
        guard Self.isUsable(pageFrame), Self.isUsable(viewport) else { return nil }
        guard let index = postIDs.firstIndex(of: sourceID ?? selectedID) else { return nil }
        let position = CGFloat(index) - (pageFrame.minX - viewport.minX) / viewport.width
        return CGRect(x: viewport.minX + offset(position: position, width: viewport.width),
                      y: pageFrame.minY, width: viewport.width, height: pageFrame.height)
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        !frame.isNull && frame.minX.isFinite && frame.minY.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}

private struct PostPlaceChromeIDsKey: EnvironmentKey {
    static var defaultValue: Set<UUID> { [] }
}

extension EnvironmentValues {
    /// Membership is stable while swiping. Selection must not change a video's
    /// avatar size, footer layout, or whether its in-page chrome is hidden.
    var postPlaceChromeIDs: Set<UUID> {
        get { self[PostPlaceChromeIDsKey.self] }
        set { self[PostPlaceChromeIDsKey.self] = newValue }
    }
}

enum PostPlaceChromeRole: Hashable, CaseIterable {
    case avatar, header, capsule, footer
}

/// Grouped Posts use one author/action scaffold even when the selected media
/// changes from a fitted photo to full-bleed video. This changes no single-Post
/// layout, and no dimensions are inferred from the incoming media's aspect ratio.
struct PostPlaceChromeGeometry {
    /// Dots belong to the whole card, not the footer's avatar-indented column.
    /// Follow the pinned group's translation only when it leaves the viewport.
    static func pageDotsOffset(footerFrame: CGRect, viewport: CGRect,
                               horizontalOffset: CGFloat) -> CGFloat {
        viewport.midX + horizontalOffset - footerFrame.midX
    }

    static func viewport(for pageFrame: CGRect, in pagerViewport: CGRect,
                         cardFrame: CGRect? = nil) -> CGRect {
        // Only horizontal paging is pinned. Expanded cards live inside a
        // vertical discussion scroll view, so their chrome must leave with
        // the card rather than covering the comments and input below it.
        let verticalFrame = cardFrame ?? pageFrame
        return CGRect(x: pagerViewport.minX, y: verticalFrame.minY,
                      width: pagerViewport.width, height: verticalFrame.height)
    }

    static func frame(for role: PostPlaceChromeRole, sourceSize: CGSize,
                      viewport: CGRect, horizontalOffset: CGFloat,
                      hasSeparateAvatar: Bool, footerHeight: CGFloat,
                      bottomSafeArea: CGFloat = 0) -> CGRect {
        let side: CGFloat = 18
        let avatar: CGFloat = 36
        let leading = side + (hasSeparateAvatar ? avatar + 10 : 0)
        let footerHeight = max(44, footerHeight)
        let footerY = viewport.maxY - max(0, bottomSafeArea) - 10 - footerHeight
        let x = viewport.minX + horizontalOffset
        switch role {
        case .avatar:
            return CGRect(x: x + side, y: viewport.minY + 16, width: avatar, height: avatar)
        case .header:
            return CGRect(x: x + leading, y: viewport.minY + 16,
                          width: max(0, viewport.width - leading - side), height: sourceSize.height)
        case .footer:
            return CGRect(x: x + leading, y: footerY,
                          width: max(0, viewport.width - leading - side), height: footerHeight)
        case .capsule:
            return CGRect(x: x + leading, y: footerY - 4 - sourceSize.height,
                          width: max(0, viewport.width - leading - side), height: sourceSize.height)
        }
    }
}

private struct PostPlaceChromePartID: Hashable {
    let postID: UUID
    let role: PostPlaceChromeRole
}

private struct PostPlaceChromePart {
    let anchor: Anchor<CGRect>
    let content: AnyView
    let isOverMedia: Bool
    let palette: PostCardPalette
    let colorScheme: ColorScheme
}

private struct PostPlaceChromePreferences {
    var pages: [UUID: Anchor<CGRect>] = [:]
    var cards: [UUID: Anchor<CGRect>] = [:]
    var parts: [PostPlaceChromePartID: PostPlaceChromePart] = [:]
}

private struct PostPlaceChromePreferenceKey: PreferenceKey {
    static var defaultValue: PostPlaceChromePreferences { .init() }

    static func reduce(value: inout PostPlaceChromePreferences,
                       nextValue: () -> PostPlaceChromePreferences) {
        let next = nextValue()
        value.pages.merge(next.pages, uniquingKeysWith: { _, latest in latest })
        value.cards.merge(next.cards, uniquingKeysWith: { _, latest in latest })
        value.parts.merge(next.parts, uniquingKeysWith: { _, latest in latest })
    }
}

/// Keep the original view as an invisible layout placeholder, and lift only its
/// chrome into the pager overlay. The card, player and presentation state are
/// never copied. Closures and counts still belong to this specific Post.
private struct PostStationaryChromePart<Content: View>: View {
    let postID: UUID
    let role: PostPlaceChromeRole
    let isOverMedia: Bool
    let content: Content
    @Environment(\.postPlaceChromeIDs) private var groupedIDs
    @Environment(\.postCardPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if groupedIDs.contains(postID) {
            content
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .anchorPreference(key: PostPlaceChromePreferenceKey.self, value: .bounds) { anchor in
                    .init(parts: [.init(postID: postID, role: role):
                        .init(anchor: anchor, content: AnyView(content), isOverMedia: isOverMedia,
                              palette: palette, colorScheme: colorScheme)])
                }
        } else {
            content
        }
    }
}

private struct PostPlaceChromePage: ViewModifier {
    let postID: UUID
    var isCard = false
    @Environment(\.postPlaceChromeIDs) private var groupedIDs

    func body(content: Content) -> some View {
        content.background {
            // A sibling preference source merges with the part preferences.
            // Do not transform/replace their value at the card's outer node.
            Color.clear.anchorPreference(key: PostPlaceChromePreferenceKey.self, value: .bounds) { anchor in
                guard groupedIDs.contains(postID) else { return .init() }
                return isCard ? .init(cards: [postID: anchor]) : .init(pages: [postID: anchor])
            }
        }
    }
}

private struct FixedPostPlaceChrome: ViewModifier {
    let groups: [PostPlaceGroup]
    let selectedID: UUID
    let isExpanded: Bool

    func body(content: Content) -> some View {
        let runs = groups.compactMap { group -> PostPlaceChromeRun? in
            guard let first = group.posts.first else { return nil }
            return PostPlaceChromeRun(groups: [group], selectedID:
                group.posts.contains(where: { $0.id == selectedID }) ? selectedID : first.id)
        }
        content
            .environment(\.postPlaceChromeIDs, Set(runs.flatMap(\.postIDs)))
            .overlayPreferenceValue(PostPlaceChromePreferenceKey.self) { preferences in
                GeometryReader { geometry in
                    ForEach(runs) { run in
                        chrome(for: run, preferences: preferences, geometry: geometry)
                    }
                }
                .clipped()
                .accessibilityIdentifier("post.place.fixed-chrome")
            }
    }

    @ViewBuilder
    private func chrome(for run: PostPlaceChromeRun, preferences: PostPlaceChromePreferences,
                        geometry: GeometryProxy) -> some View {
        let pagerViewport = CGRect(origin: .zero, size: geometry.size)
        let pages = preferences.pages.mapValues { geometry[$0] }
        let availableParts = Set(preferences.parts.keys.map(\.postID))
        if let sourceID = run.sourceID(pageFrames: pages, availableParts: availableParts,
                                      viewport: pagerViewport, prefersSelected: run.contains(selectedID)),
           let pageFrame = pages[sourceID],
           let frame = run.frame(pageFrame: pageFrame, viewport: pagerViewport, sourceID: sourceID) {
            let cardFrame = isExpanded ? preferences.cards[sourceID].map { geometry[$0] } : nil
            let viewport = PostPlaceChromeGeometry.viewport(for: frame, in: pagerViewport, cardFrame: cardFrame)
            let hasAvatar = preferences.parts[.init(postID: sourceID, role: .avatar)] != nil
            let footerHeight = preferences.parts[.init(postID: sourceID, role: .footer)]
                .map { geometry[$0.anchor].height } ?? 44
            ForEach(PostPlaceChromeRole.allCases, id: \.self) { role in
                if let part = preferences.parts[.init(postID: sourceID, role: role)] {
                    let partFrame = PostPlaceChromeGeometry.frame(
                        for: role, sourceSize: geometry[part.anchor].size,
                        viewport: viewport, horizontalOffset: frame.minX - viewport.minX,
                        hasSeparateAvatar: hasAvatar, footerHeight: footerHeight,
                        bottomSafeArea: geometry.safeAreaInsets.bottom)
                    part.content
                        .frame(width: partFrame.width, height: partFrame.height,
                               alignment: role == .header ? .topLeading : .center)
                        .overlay(alignment: .bottom) {
                            if role == .footer {
                                PostPlacePageDots(count: run.postIDs.count,
                                    index: run.postIDs.firstIndex(of: sourceID) ?? run.selectedIndex,
                                    isOverMedia: part.isOverMedia)
                                    .offset(x: PostPlaceChromeGeometry.pageDotsOffset(
                                        footerFrame: partFrame, viewport: viewport,
                                        horizontalOffset: frame.minX - viewport.minX), y: 7)
                                    .allowsHitTesting(false)
                            }
                        }
                        .environment(\.postCardPalette, part.palette)
                        .environment(\.colorScheme, part.colorScheme)
                        .position(x: partFrame.midX, y: partFrame.midY)
                }
            }
            // Incoming/fallback chrome is visual until its actual Post wins
            // selection. Never send an engagement action to an unselected Post.
            .allowsHitTesting(sourceID == selectedID)
            .accessibilityHidden(sourceID != selectedID)
        }
    }
}

/// Same quiet window of dots as the place pager, adapted to either Post palette.
private struct PostPlacePageDots: View {
    let count: Int
    let index: Int
    let isOverMedia: Bool
    @Environment(\.postCardPalette) private var palette

    private var visibleRange: Range<Int> {
        let start = max(0, min(index - 3, count - 7))
        return start..<min(count, start + 7)
    }

    var body: some View {
        if count > 1 {
            HStack(spacing: 5) {
                ForEach(visibleRange, id: \.self) { page in
                    let isOverflow = (page == visibleRange.lowerBound && page > 0)
                        || (page == visibleRange.upperBound - 1 && page < count - 1)
                    Circle()
                        .fill((isOverMedia ? Color.white : palette.primary).opacity(page == index ? 0.9 : 0.3))
                        .frame(width: 6, height: 6)
                        .scaleEffect(isOverflow && page != index ? 0.65 : 1)
                }
            }
            .animation(.easeOut(duration: 0.16), value: index)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("At this place, Post \(index + 1) of \(count)")
            .accessibilityIdentifier("post.place.position")
        }
    }
}

extension View {
    func postStationaryChrome(_ role: PostPlaceChromeRole, postID: UUID,
                              isOverMedia: Bool = false) -> some View {
        PostStationaryChromePart(postID: postID, role: role, isOverMedia: isOverMedia, content: self)
    }

    func postPlaceChromePage(postID: UUID) -> some View {
        modifier(PostPlaceChromePage(postID: postID))
    }

    func postPlaceChromeCard(postID: UUID) -> some View {
        modifier(PostPlaceChromePage(postID: postID, isCard: true))
    }

    func fixedPostPlaceChrome(groups: [PostPlaceGroup], selectedID: UUID, isExpanded: Bool) -> some View {
        modifier(FixedPostPlaceChrome(groups: groups, selectedID: selectedID, isExpanded: isExpanded))
    }
}
