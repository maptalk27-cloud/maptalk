import SwiftUI
import UIKit

/// Home-only navigation around the existing Bubble cards. A nested Bubble
/// has its own cursor; its parent stays mounted and resumes exactly on Back.
struct HomeBubbleContentView: View {
    let scope: MapJourneyScope
    @Binding var selection: UUID?
    let isExpanded: Bool
    let isActive: Bool
    let onExpand: () -> Void
    let onBack: () -> Void
    let onClose: () -> Void
    let onJourney: (JourneyPost) -> Void
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?
    let onRead: (String) -> Void
    let viewedKeys: Set<String>

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appEnv) private var environment
    @Environment(\.profileCardSheetMotion) private var motion
    @AppStorage(PostCardPalette.storageKey) private var palette: PostCardPalette = .white
    @State private var activeChildPresentations: Set<UUID> = []
    @State private var isKeyboardVisible = false
    @State private var selectedPageID: UUID?

    private var items: [ExperienceDetailView.SequencePager.Item] { scope.sequenceItems }
    private var pages: [HomeBubblePage] { HomeBubblePage.pages(in: scope) }
    private var pageItems: [ExperienceDetailView.SequencePager.Item] {
        pages.map { .init(id: $0.id, mode: $0.mode) }
    }
    private var currentPage: HomeBubblePage? {
        if let page = pages.first(where: { $0.id == selectedPageID }),
           page.memberID == selection { return page }
        return pages.first(where: { $0.memberID == selection }) ?? pages.first
    }
    private var poiChromePages: [FriendStoryPOIChromePage] {
        pages.map { page in
            let place: RatedPOI?
            if case let .poi(rated) = page.mode, page.media != nil {
                place = rated
            } else { place = nil }
            return .init(id: page.id.uuidString, place: place)
        }
    }
    private var selectedIndex: Int {
        items.firstIndex { $0.id == selection } ?? 0
    }
    private var canNavigate: Bool {
        isActive && scenePhase == .active && activeChildPresentations.isEmpty && !isKeyboardVisible
    }
    private var title: String {
        let title = scope.journey.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Bubble" : title
    }

    var body: some View {
        let chromePages = poiChromePages
        let chromeSelection = currentPage?.id.uuidString ?? ""
        let chromeRun = FriendStoryPOIChromeRun(pages: chromePages, selectedID: chromeSelection)
        return Group {
            if let currentPage, let motion {
                ProfileSequencePager(items: pageItems,
                    selection: Binding(get: { self.currentPage?.id ?? currentPage.id }, set: selectPage),
                    isExpanded: isExpanded, motion: motion, isActive: isActive,
                    background: { item in isPost(item) ? palette.background : .black }) { item in
                    if let page = pages.first(where: { $0.id == item.id }) {
                        pageContent(page, chromeRun: chromeRun)
                    }
                }
            } else if let currentPage {
                TabView(selection: Binding(get: { self.currentPage?.id ?? currentPage.id }, set: selectPage)) {
                    ForEach(pages) { page in pageContent(page, chromeRun: chromeRun).tag(page.id) }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            } else {
                MapJourneyEmptyCapsule()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fixedPOIChrome(pages: chromePages, selectedID: chromeSelection,
                       showsPageDots: true)
        .ignoresSafeArea(.container, edges: .bottom)
        .environment(\.friendStoryPlaybackEnabled,
                     isActive && scenePhase == .active && activeChildPresentations.isEmpty)
        .environment(\.friendStoryChildPresentationChanged, { id, presented in
            if presented { activeChildPresentations.insert(id) }
            else { activeChildPresentations.remove(id) }
        })
        .modifier(FriendStoryCardHeader(isEnabled: true, isVisible: canNavigate) {
                navigationHeader
                    .environment(\.colorScheme, .dark)
                    .environment(\.appEnv, environment)
        })
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
    }

    private func pageContent(_ page: HomeBubblePage, chromeRun: FriendStoryPOIChromeRun?) -> some View {
        let item = ExperienceDetailView.SequencePager.Item(id: page.id, mode: page.mode)
        let isSelected = currentPage?.id == page.id
        let playbackActive = isActive && scenePhase == .active
            && activeChildPresentations.isEmpty && isSelected
        return Group {
            if case let .poi(place) = page.mode, let media = page.media {
                // These bytes belong to the saved visit, not the shared
                // landmark's latest activity or its aggregate media list.
                // Keep the same edge-to-edge memory when the Bubble grows;
                // expanding it must not replace the media with place details.
                FriendStoryPOIPreview(place: place, media: media, isPlaybackActive: playbackActive,
                    showsPlaceChrome: chromeRun?.contains(page.id.uuidString) != true,
                    chromePageID: page.id.uuidString)
            } else {
                ExperienceDetailView(
                    mode: page.mode,
                    isExpanded: isExpanded,
                    usesClassicPostPreview: true,
                    recordsActiveCompactViewportOnly: true,
                    poiStorySelection: page.poiSelection,
                    expandedPOIMedia: page.media,
                    onCollapsedTap: onExpand,
                    onJourneyAvatarStackTap: { bubble in
                        guard canNavigate else { return }
                        // Pin the actual tapped member before nesting, even
                        // if its horizontal swipe hasn't reached idle yet.
                        selectedPageID = page.id
                        if selection != page.memberID { selection = page.memberID }
                        onJourney(bubble)
                    },
                    journeyProvider: journeyProvider,
                    userProvider: userProvider,
                    onPOIContributorViewed: { $0.forEach(onRead) },
                    isPOIContributorUnseen: { keys in keys.contains { !viewedKeys.contains($0) } }
                )
            }
        }
        .environment(\.postCardPalette, isPost(item) ? palette : .white)
        .environment(\.colorScheme, isPost(item) ? palette.colorScheme : .dark)
        .environment(\.friendStoryPlaybackEnabled, playbackActive)
        .background(isPost(item) ? palette.background : .black)
        .background(ExperiencePagerVerticalBounceGuard())
        .accessibilityHidden(!isSelected)
    }

    private var navigationHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Back to previous content")
                .accessibilityIdentifier("maptalk.friend-story.back")

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !items.isEmpty {
                    Text("\(selectedIndex + 1) / \(items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .accessibilityHidden(true)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close browsing")
                .accessibilityIdentifier("maptalk.friend-story.close")
            }
            .padding(.horizontal, 4)
            .frame(height: 44)

            StorySequenceProgressBar(count: items.count, index: selectedIndex) { index in
                guard items.indices.contains(index) else { return }
                select(items[index].id)
            }
            .frame(height: 24)
            .padding(.horizontal, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Memory \(items.isEmpty ? 0 : selectedIndex + 1) of \(items.count)")
            .accessibilityValue(title)
            .accessibilityIdentifier("home-bubble.progress.\(scope.journey.id.uuidString)")
            .accessibilityAdjustableAction { direction in
                let target = selectedIndex + (direction == .increment ? 1 : -1)
                guard items.indices.contains(target) else { return }
                select(items[target].id)
            }
            .allowsHitTesting(!items.isEmpty)
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-bubble.navigation")
        .accessibilityAction(.escape, onBack)
    }

    private func select(_ id: UUID) {
        guard let page = pages.first(where: { $0.memberID == id }) else { return }
        selectPage(page.id)
    }

    private func selectPage(_ id: UUID) {
        // Let an in-flight swipe land before accepting a second navigation
        // gesture. The pager clears isPaging before committing its own cursor.
        guard canNavigate, motion?.isPaging != true,
              let page = pages.first(where: { $0.id == id }) else { return }
        selectedPageID = page.id
        // Several saved photos can belong to one place. Changing the photo
        // must not fly the map again or count as another Bubble member.
        if selection != page.memberID { selection = page.memberID }
    }

    private func isPost(_ item: ExperienceDetailView.SequencePager.Item) -> Bool {
        if case .real = item.mode { return true }
        return false
    }
}
