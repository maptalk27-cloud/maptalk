#if DEBUG
import MapKit
import SwiftUI

enum POIVisitCountPreviewStyle: String, CaseIterable {
    case footprint = "A 原版"
    case softWhite = "B 柔白"
    case mutedMint = "C 淡薄荷"

    var iconSize: CGFloat {
        switch self {
        case .footprint: 12
        case .softWhite: 16
        case .mutedMint: 20
        }
    }

    var numberSize: CGFloat {
        switch self {
        case .footprint: 15
        case .softWhite: 18
        case .mutedMint: 20
        }
    }

    var iconColor: Color {
        switch self {
        case .footprint: .white.opacity(0.55)
        case .softWhite: .white.opacity(0.72)
        case .mutedMint: Color(red: 0.69, green: 0.82, blue: 0.77).opacity(0.85)
        }
    }

    var numberColor: Color {
        switch self {
        case .footprint: .white.opacity(0.78)
        case .softWhite: .white.opacity(0.88)
        case .mutedMint: .white.opacity(0.9)
        }
    }
}

private struct POIVisitCountPreviewStyleKey: EnvironmentKey {
    static let defaultValue: POIVisitCountPreviewStyle? = nil
}

extension EnvironmentValues {
    var poiVisitCountPreviewStyle: POIVisitCountPreviewStyle? {
        get { self[POIVisitCountPreviewStyleKey.self] }
        set { self[POIVisitCountPreviewStyleKey.self] = newValue }
    }
}

/// Presentation-only choices for the existing count; never substitute fixture totals.
struct POIVisitCountPreviewMark: View {
    let number: String
    let style: POIVisitCountPreviewStyle

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "shoeprints.fill")
                .font(.system(size: style.iconSize, weight: .regular))
                .foregroundStyle(style.iconColor)
            Text(number)
                .font(.system(size: style.numberSize, weight: .medium))
                .foregroundStyle(style.numberColor)
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 40)
    }
}

/// Local fixture comparison only; shared card chrome, no account mutations.
struct POICardDesignPreview: View {
    let onClose: () -> Void
    private enum Design: String, CaseIterable {
        case original = "1 Original", inCard = "2 Updated"
    }
    private enum Context: String, CaseIterable {
        case instant = "即时浏览", overview = "地点回看"
    }
    private struct Slice: Identifiable {
        let place: RatedPOI
        let visit: RatedPOI.CheckIn
        let media: RatedPOI.Media?
        let mediaIndex: Int
        var id: String { "\(visit.id)-\(media?.id.uuidString ?? "no-media")" }
    }
    private struct RevisitPlayback: Identifiable {
        let id = UUID()
        let place: RatedPOI
        let contributors: [ExperienceDetailView.POIStoryContributor]
        let initialIndex: Int
        let accentColor: Color
        let sourceID: ExperienceDetailView.POIRecentSharersRow.TransitionID
    }
    private struct FriendPlaceDetail {
        let placeID: UUID
        let returnExpanded: Bool
    }

    @State private var design: Design = .inCard
    @State private var context: Context = .instant
    @State private var scenario: POICardPreviewCase = .repeated
    @State private var mediaKind: POICardPreviewCase.MediaKind = .mixed
    @State private var hasFeedback = true
    @State private var showsMediaText = true
    @State private var visitCountStyle: POIVisitCountPreviewStyle = .softWhite
    // Show the latest repeat visit's feeling, note and photo in the author-bar preview.
    @State private var sliceIndex = 2
    @State private var historyPersonID: UUID?
    @State private var scopedPlaceID: UUID?
    @State private var selectedMapPlaceID: UUID?
    @State private var selectedProfile: UserMapViewModel.Context?
    @State private var revisitPlayback: RevisitPlayback?
    @State private var revisitProfile: User?
    @State private var browsingHistory = false
    @StateObject private var interactionPresentation = POIPreviewInteractionPresentation()
    @StateObject private var revisitInteractions = POIPreviewInteractionPresentation()
    @State private var likedMediaIDs: Set<UUID> = []
    @State private var mediaComments: [UUID: String] = [:]
    @State private var mediaReplies: [UUID: String] = [:]
    @State private var savedPlaces: [UUID: Bool] = [:]
    @State private var friendPlaceDetail: FriendPlaceDetail?
    @StateObject private var presentation = MapTalkCardPresentation(
        poiCompactFraction: 0.35, postCompactFraction: 0.48)
    @State private var environment = AppEnvironment.bootstrap()
    @State private var referenceDate = Date()
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var hasInitializedPreview = false
    @Namespace private var revisitTransition

    private var isExpanded: Bool { presentation.poi.isExpanded }
    private var focusesOnFriend: Bool { design != .original }
    private var usesOriginalPresentation: Bool { design == .original || context == .overview }
    private var usesRevisitPeople: Bool { design == .inCard && context == .overview }
    private var showsSlices: Bool { context == .instant || browsingHistory }
    private var fixtures: [RatedPOI] {
        scenario.makeFixtures(media: mediaKind, hasFeedback: hasFeedback, now: referenceDate)
    }
    private var fixture: RatedPOI {
        let places = fixtures
        let fallback = places.first { $0.id == scopedPlaceID } ?? places[0]
        let pages = slices(fallback)
        return pages.isEmpty ? fallback : pages[min(sliceIndex, pages.count - 1)].place
    }
    private var contextSelection: Binding<Context> {
        Binding(get: { context }, set: { value in
            let selectedPlaceID = fixture.id
            resetBrowsing()
            scopedPlaceID = value == .overview ? selectedPlaceID : nil
            context = value
        })
    }
    private var designSelection: Binding<Design> {
        Binding(get: { design }, set: { value in
            let placeID = fixture.id
            resetBrowsing()
            design = value
            if context == .overview {
                scopedPlaceID = placeID
            }
        })
    }
    private var originalUserProvider: (UUID) -> User? {
        let users = [PreviewData.currentUser] + PreviewData.sampleFriends + POICardPreviewCase.customizedFriends
        return { id in users.first { $0.id == id } }
    }
    private var expandedSelection: Binding<Bool> {
        Binding(get: { isExpanded }, set: { expanded in
            if !presentation.isPresented { presentation.poi.presentNewContent() }
            presentation.poi.detent = expanded ? .large : presentation.poi.compactDetent
        })
    }

    var body: some View {
        ZStack {
            Map(position: $mapPosition, selection: $selectedMapPlaceID) {
                ForEach(fixtures) { place in
                    Marker(place.poi.name, coordinate: place.poi.coordinate)
                        .tint(place.poi.category.accentColor)
                        .tag(place.id)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .environment(\.colorScheme, .light)
            .mapControlVisibility(.hidden).ignoresSafeArea()
            VStack(spacing: 0) {
                controls
                Color.clear.allowsHitTesting(false)
            }.ignoresSafeArea(.container, edges: .bottom)
        }
        .appEnvironment(environment).preferredColorScheme(.light)
        .accessibilityIdentifier("maptalk.poi-card-design-preview")
        .onAppear {
            // Returning from a full-screen child must not recenter the map
            // or reopen/reset the card that was kept beneath it.
            guard !hasInitializedPreview else { return }
            hasInitializedPreview = true
            focusSelectedPlace()
            presentation.poi.presentNewContent()
        }
        .onChangeCompat(of: scenario) { _ in resetBrowsing() }
        .onChangeCompat(of: mediaKind) { _ in resetBrowsing() }
        .onChangeCompat(of: selectedMapPlaceID) { id in
            guard let id else { return }
            // Marker selection is only the tap, not the scope of the open card.
            selectedMapPlaceID = nil
            openMapPlace(id)
        }
        .onChangeCompat(of: fixture.id) { _ in focusSelectedPlace() }
        .onChangeCompat(of: historyPersonID) { _ in
            if !browsingHistory { sliceIndex = 0 }
        }
        .onChangeCompat(of: isExpanded) { expanded in
            // A downward gesture returns to the retained story at compact size.
            // Do not expand again after UIKit has just finished collapsing.
            if !expanded { friendPlaceDetail = nil }
        }
        .background(HomeCardNativePresenter(
            presentation: presentation,
            compactFraction: 0.35,
            expandedTopInset: FriendStoryLayout.floatingHeight,
            selectedSource: nil,
            backgroundColor: .black,
            content: AnyView(card
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.poiVisitCountPreviewStyle, visitCountStyle)
                .environment(\.profileCardSheetMotion, presentation.motion)
                .appEnvironment(environment)),
            onDismiss: { _ = presentation.didDismiss(.personStory) }
        ))
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("POI 卡片对照").font(.headline)
                Spacer()
                if usesRevisitPeople, browsingHistory {
                    Button("返回地点", action: returnToPlaceOverview)
                        .font(.caption)
                } else if friendPlaceDetail != nil {
                    Button("返回动态", action: returnToFriendStory)
                        .font(.caption)
                } else if presentation.isPresented {
                    Text("仅示例").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("显示卡片") { presentation.poi.presentNewContent() }
                        .font(.caption)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 44, height: 36)
                }.buttonStyle(.plain).accessibilityLabel("关闭预览")
            }
            Picker("设计", selection: designSelection) {
                ForEach(Design.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            HStack(spacing: 10) {
                Picker("浏览场景", selection: contextSelection) {
                    ForEach(Context.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("卡片大小", selection: expandedSelection) {
                    Text("缩略").tag(false)
                    Text("全屏").tag(true)
                }.frame(width: 120)
            }.pickerStyle(.segmented)
            HStack {
                Menu {
                    Picker("打卡组合", selection: $scenario) {
                        ForEach(POICardPreviewCase.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(scenario.title).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2.bold())
                    }.frame(minHeight: 36)
                }.accessibilityIdentifier("poi-preview.scenario")
                Spacer()
                Toggle(usesOriginalPresentation ? "点评" : "心情", isOn: $hasFeedback).fixedSize().font(.caption)
            }
            Picker("媒体", selection: $mediaKind) {
                ForEach(POICardPreviewCase.MediaKind.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if design == .inCard, context == .instant {
                Picker("画面文字", selection: $showsMediaText) {
                    Text("原图／原视频").tag(false)
                    Text("画面带字").tag(true)
                }.pickerStyle(.segmented)
                    .disabled(mediaKind == .none)
                Picker("到访次数样式", selection: $visitCountStyle) {
                    ForEach(POIVisitCountPreviewStyle.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("poi-preview.visit-count-style")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(scenario.subtitle).lineLimit(2)
                Text(fixtureSummary)
                    .monospacedDigit()
            }.font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(.black).padding(.horizontal, 16).padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var fixtureSummary: String {
        let places = fixtures
        let visits = places.flatMap(\.checkIns)
        let people = Set(visits.map(\.userId)).count
        let mediaCount = places.reduce(0) { $0 + $1.media.count }
        return "\(people) 人 · \(places.count) 地点 · \(visits.count) 次到访 · \(mediaCount) 张／段 · 上滑全屏"
    }

    private func focusSelectedPlace() {
        mapPosition = .camera(MapCamera(centerCoordinate: fixture.poi.coordinate,
            distance: 2_400, heading: -12, pitch: 42))
    }

    private var card: some View {
        let place = fixture
        return ZStack {
            // Keep the original pager and its exact media selection mounted.
            originalCard(place)
                .opacity(friendPlaceDetail == nil ? 1 : 0)
                .allowsHitTesting(friendPlaceDetail == nil)
                .accessibilityHidden(friendPlaceDetail != nil)

            if let route = friendPlaceDetail,
               let detail = fixtures.first(where: { $0.id == route.placeID }) {
                friendPlaceDetailCard(detail)
            }
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .environment(\.experiencePOIHistoryVisible, usesOriginalPresentation)
        .environment(\.experiencePOIVisitorSummary, revisitPeople(place))
        .environment(\.experiencePOIFootprintsVisible, !usesRevisitPeople)
        .environment(\.experiencePOIPlaceHeader, friendPlaceHeader)
        .environment(\.experiencePOIPlaceTrailingAction, overviewPlaceAction)
        .modifier(POIPreviewInteractionSheet(presentation: interactionPresentation,
            localComments: $mediaComments, localReplies: $mediaReplies))
        // A place overview represents everyone, not one active author.
        .modifier(FriendStoryCardHeader(
            isEnabled: context == .instant && originalPages(place).isEmpty,
            isVisible: presentation.isPresented && selectedProfile == nil
        ) {
            previewPersonBar(place)
                .environment(\.colorScheme, .dark)
                .appEnvironment(environment)
        })
        .fullScreenCover(item: $revisitPlayback, onDismiss: {
            revisitInteractions.context = nil
            if let user = revisitProfile {
                revisitProfile = nil
                selectedProfile = .profileContext(for: user)
            }
        }) { playback in
            ExperienceDetailView.POIStoryViewer(
                contributors: playback.contributors,
                initialIndex: playback.initialIndex,
                accentColor: playback.accentColor,
                onUserSelected: { revisitProfile = $0 },
                usesQuietChrome: true,
                isInteractionPresented: revisitInteractions.pausesPlayback,
                bottomActions: { contributor, item in
                    revisitActions(for: contributor, item: item, place: playback.place)
                },
                onClose: { revisitPlayback = nil }
            )
            .modifier(POIPreviewInteractionSheet(presentation: revisitInteractions,
                localComments: $mediaComments, localReplies: $mediaReplies))
            .environment(\.friendStoryExpectedMedia, [])
            .environment(\.friendStoryOnMediaReady, nil)
            .environment(\.friendStoryPlaybackEnabled, true)
            .environment(\.friendStoryChildPresentationChanged, nil)
            .environment(\.postPlaceChromeIDs, [])
            .appEnvironment(environment)
            // Style this content only; do not switch presentation appearance
            // while the light map is still visible behind the zoom.
            .environment(\.colorScheme, .dark)
            .navigationTransition(.zoom(sourceID: playback.sourceID, in: revisitTransition))
        }
        .fullScreenCover(item: $selectedProfile) { context in
            NavigationStack {
                UserProfileView(viewModel: .init(environment: environment, context: context),
                                showsCloseButton: true)
            }.appEnvironment(environment)
        }
        // Detent is deliberately not an identity: resizing keeps the player.
        .id("\(scenario.rawValue)-\(context.rawValue)-\(mediaKind.rawValue)-\(browsingHistory)")
    }

    private func friendPlaceDetailCard(_ place: RatedPOI) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: returnToFriendStory) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回刚才的动态")
                .accessibilityIdentifier("poi.preview.place-detail.back")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            ExperienceDetailView(ratedPOI: place, isExpanded: true,
                userProvider: originalUserProvider,
                isPOIContributorUnseen: { _ in false })
                .environment(\.experiencePOIHistoryVisible, true)
                .environment(\.experiencePOIVisitorSummary, revisitPeople(place, isPlaceDetail: true))
                .environment(\.experiencePOIFootprintsVisible, false)
                .environment(\.experiencePOIPlaceHeader, updatedPlaceHeader(opensDetail: false))
                .environment(\.experiencePOIPlaceTrailingAction, overviewPlaceAction)
        }
        .background(Color.black)
        .accessibilityAction(.escape, returnToFriendStory)
    }

    @ViewBuilder
    private func previewPersonBar(_ place: RatedPOI) -> some View {
        let pages = originalPages(place)
        if !pages.isEmpty {
            let current = pages[min(sliceIndex, pages.count - 1)]
            let author = originalUserProvider(current.authorID)
            let group = FriendStoryGroup(authorID: current.authorID, user: author,
                pages: pages.filter { $0.authorID == current.authorID })
            FriendStoryNavigationHeader(author: author, group: group, page: current,
                pageIndex: group.pages.firstIndex { $0.id == current.id } ?? 0,
                canNavigate: presentation.isPresented,
                onAuthor: {
                    if let author { selectedProfile = .profileContext(for: author) }
                },
                onPreviousPage: { sliceIndex = max(0, sliceIndex - 1) },
                onNextPage: { sliceIndex = min(pages.count - 1, sliceIndex + 1) },
                onSelectPage: { index in
                    guard group.pages.indices.contains(index),
                          let selected = pages.firstIndex(where: { $0.id == group.pages[index].id }) else { return }
                    sliceIndex = selected
                    if context == .overview { browsingHistory = true }
                },
                onClose: { presentation.dismiss() })
        } else {
            // Empty fixtures retain the same floating surface without claiming
            // that a person has visited or inventing a story progress bar.
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 30)).foregroundStyle(.white.opacity(0.55))
                Text(place.checkIns.isEmpty ? "暂无打卡" : "暂无近期动态")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Spacer()
            }.padding(.horizontal, 16).frame(height: FriendStoryLayout.headerHeight)
        }
    }

    /// The complete shipping story includes its floating author/progress bar,
    /// stable place chrome and the native media pager, not just card artwork.
    @ViewBuilder
    private func originalCard(_ place: RatedPOI) -> some View {
        if showsSlices {
            let pages = originalPages(place)
            if pages.isEmpty {
                emptyState(place, active: context == .instant)
            } else {
                let current = pages[min(sliceIndex, pages.count - 1)]
                originalStory(place, pages: pages, current: current)
            }
        } else {
            ExperienceDetailView(ratedPOI: place, isExpanded: isExpanded,
                onCollapsedTap: { presentation.poi.expand() },
                userProvider: originalUserProvider,
                isPOIContributorUnseen: { _ in false })
        }
    }

    private func originalPages(_ place: RatedPOI) -> [FriendStoryPage] {
        slices(place).map { slice in
            let expected: [FriendStoryMediaDescriptor] = slice.media.map { media in
                let kind: FriendStoryMediaDescriptor.Kind
                switch media.kind {
                case .photo: kind = .photo
                case .video: kind = .video
                }
                return [.init(id: media.id, kind: kind)]
            } ?? []
            return FriendStoryPage(id: slice.id, authorID: slice.visit.userId,
                memoryID: slice.visit.id, mediaID: slice.media?.id,
                publishedAt: slice.visit.activityDate, capturedAt: slice.visit.createdAt,
                expiresAt: slice.visit.activityDate.addingTimeInterval(StoryReadKeys.freshWindow),
                readKey: "preview-\(slice.id)", kind: slice.media == nil ? .poiLocationOnly : .poiMedia,
                expectedMedia: expected, content: .poi(slice.place, slice.visit, slice.media))
        }
    }

    private func originalStory(_ place: RatedPOI, pages: [FriendStoryPage],
                               current: FriendStoryPage) -> some View {
        let group = FriendStoryGroup(authorID: current.authorID,
            user: originalUserProvider(current.authorID),
            pages: pages.filter { $0.authorID == current.authorID })
        let selection = Binding<String>(get: { pages[min(sliceIndex, pages.count - 1)].id }, set: { id in
            guard friendPlaceDetail == nil else { return }
            if let index = pages.firstIndex(where: { $0.id == id }) { sliceIndex = index }
        })
        let places = fixtures
        return FriendStoryContentView(group: group, page: current,
            pageIndex: group.pages.firstIndex(where: { $0.id == current.id }) ?? 0,
            pagerPages: pages, pagerUserProvider: originalUserProvider,
            selectedPageID: selection, viewedKeys: [], isExpanded: isExpanded,
            isPlaybackActive: presentation.isPresented && friendPlaceDetail == nil
                && !interactionPresentation.pausesPlayback,
            onPreviousPage: { sliceIndex = max(0, sliceIndex - 1) },
            onNextPage: { sliceIndex = min(pages.count - 1, sliceIndex + 1) },
            onSelectPage: { index in
                guard group.pages.indices.contains(index) else { return }
                selection.wrappedValue = group.pages[index].id
            },
            onExpand: { presentation.poi.expand() },
            onClose: { presentation.dismiss() },
            onJourney: { _, _ in }, onReadReady: { _ in },
            journeyProvider: { _ in nil }, userProvider: originalUserProvider,
            placeProvider: { id in places.first { $0.id == id } },
            showsFloatingHeader: context == .instant,
            showsVisitExpression: focusesOnFriend && context == .instant,
            showsPersonalVisitCount: focusesOnFriend && context == .instant,
            showsHeaderTimestamp: !(focusesOnFriend && context == .instant),
            placeAuthors: mapPlaceAuthors(pages),
            allowsPOIMediaLightbox: !(focusesOnFriend && context == .instant),
            mediaDecoration: previewMediaDecoration)
            .environment(\.experienceLiveMediaHydrationEnabled, false)
            // New variants focus instant viewing on the current moment;
            // place history remains available through the overview.
            .environment(\.experiencePOIRecentSharersVisible, usesOriginalPresentation)
            .environment(\.experiencePOIPlaybackActions,
                design != .original ? playbackActions(for: current) : nil)
    }

    private func mapPlaceAuthors(_ pages: [FriendStoryPage]) -> [User] {
        guard design == .inCard, context == .instant, scopedPlaceID != nil else { return [] }
        var seen = Set<UUID>()
        return pages.compactMap { page in
            guard seen.insert(page.authorID).inserted else { return nil }
            return originalUserProvider(page.authorID)
        }
    }

    private var previewMediaDecoration: ((RatedPOI.Media) -> AnyView)? {
        guard design == .inCard, context == .instant, showsMediaText else { return nil }
        return { media in AnyView(POIPreviewMediaText(media: media)) }
    }

    private func playbackActions(for page: FriendStoryPage) -> AnyView? {
        guard design != .original, context == .instant,
              case let .poi(place, _, media) = page.content else { return nil }
        return AnyView(ZStack(alignment: .trailing) {
            Color.clear.frame(height: 44).allowsHitTesting(false)
            if let media, page.authorID != PreviewData.currentUser.id {
                POIPreviewInteractionBar(media: media, authorID: page.authorID,
                    authorName: personName(page.authorID), placeName: place.poi.name,
                    likedMediaIDs: $likedMediaIDs, localComments: $mediaComments,
                    localReplies: $mediaReplies, usesPrivateReply: true,
                    compact: true, showsShare: false,
                    iconSize: 20, presentation: interactionPresentation)
            }
        }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if let destination = MapDirectionsDestination(name: place.poi.name,
                       coordinate: place.poi.coordinate) {
                    PlaceDirectionsButton(destination: destination)
                        .shadow(color: .black.opacity(0.55), radius: 1.5, y: 1)
                }
            }
            .overlay(alignment: .topLeading) {
                Text(page.publishedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                    .offset(y: -14)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("poi.preview.visit.timestamp")
            })
    }

    private var friendPlaceHeader: ((UUID) -> AnyView?)? {
        updatedPlaceHeader(opensDetail: context == .instant)
    }

    private func updatedPlaceHeader(opensDetail: Bool) -> ((UUID) -> AnyView?)? {
        guard focusesOnFriend else { return nil }
        let places = fixtures
        let saved = savedPlaces
        return { id in
            guard let place = places.first(where: { $0.id == id }) else { return nil }
            let isSaved = saved[id] ?? place.isFavoritedByCurrentUser
            return AnyView(POIPreviewFriendPlaceHeading(place: place, isSaved: isSaved,
                onOpen: opensDetail ? { openFriendPlace(id) } : nil,
                onToggleSave: { savedPlaces[id] = !isSaved }))
        }
    }

    private func revisitActions(for contributor: ExperienceDetailView.POIStoryContributor,
                                item: ExperienceDetailView.POIStoryContributor.Item?,
                                place: RatedPOI) -> AnyView {
        let media = item.flatMap { item in place.media.first { $0.id == item.id } }
        return AnyView(HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let media, contributor.userId != PreviewData.currentUser.id {
                POIPreviewInteractionBar(media: media, authorID: contributor.userId,
                    authorName: contributor.user?.handle ?? "Friend", placeName: place.poi.name,
                    likedMediaIDs: $likedMediaIDs, localComments: $mediaComments,
                    localReplies: $mediaReplies, usesPrivateReply: true,
                    compact: true, showsShare: false, iconSize: 20,
                    presentation: revisitInteractions)
            }
        })
    }

    private var overviewPlaceAction: ((UUID) -> AnyView?)? {
        guard usesRevisitPeople || friendPlaceDetail != nil else { return nil }
        let places = fixtures
        let saved = savedPlaces
        return { id in
            guard let place = places.first(where: { $0.id == id }) else { return nil }
            let isSaved = saved[id] ?? place.isFavoritedByCurrentUser
            return AnyView(POIPreviewPlaceSaveButton(place: place, isSaved: isSaved,
                onToggle: { savedPlaces[id] = !isSaved }))
        }
    }

    private func revisitPeople(_ place: RatedPOI, isPlaceDetail: Bool = false) -> AnyView? {
        guard isPlaceDetail || (usesRevisitPeople && !browsingHistory) else { return nil }
        // Count visits (including no-media visits), not the story's media pages.
        // checkInPeople already keeps one person and orders by their latest visit.
        let people = place.checkInPeople()
        let sharers = contributors(place)
        let counts = Dictionary(uniqueKeysWithValues: people.map { ($0.userID, $0.checkIns.count) })
        return AnyView(ExperienceDetailView.POIRecentSharersRow(
            sharers: sharers,
            accentColor: place.poi.category.accentColor,
            isContributorUnseen: { _ in false },
            onSelect: { index in
                guard sharers.indices.contains(index) else { return }
                // Reuse the original full-screen place player, leaving the
                // underlying place card and its detent untouched on return.
                revisitPlayback = RevisitPlayback(place: place, contributors: sharers,
                    initialIndex: index, accentColor: place.poi.category.accentColor,
                    sourceID: .init(placeID: place.id, userID: sharers[index].userId))
            },
            wraps: isPlaceDetail || isExpanded,
            visitCounts: counts,
            transitionNamespace: revisitTransition,
            transitionPlaceID: place.id
        )
        // Match the existing comment-card bounds in both card sizes.
        .padding(.horizontal,
            ExperienceDetailView.ExperienceSheetLayout.engagementHorizontalInset
            - ExperienceDetailView.POIHeroLayout.collapsedHorizontalPadding))
    }

    private func returnToPlaceOverview() {
        historyPersonID = nil
        sliceIndex = 0
        browsingHistory = false
    }

    private func openFriendPlace(_ id: UUID) {
        guard friendPlaceDetail == nil, fixtures.contains(where: { $0.id == id }) else { return }
        friendPlaceDetail = FriendPlaceDetail(placeID: id, returnExpanded: isExpanded)
        presentation.poi.expand()
    }

    private func returnToFriendStory() {
        guard let route = friendPlaceDetail else { return }
        friendPlaceDetail = nil
        presentation.poi.detent = route.returnExpanded ? .large : presentation.poi.compactDetent
    }

    private func resetBrowsing() {
        sliceIndex = 0
        historyPersonID = nil
        scopedPlaceID = nil
        selectedMapPlaceID = nil
        browsingHistory = false
        friendPlaceDetail = nil
    }

    private func openMapPlace(_ id: UUID) {
        presentation.perform(in: .personStory) {
            guard let place = fixtures.first(where: { $0.id == id }) else { return }
            resetBrowsing()
            scopedPlaceID = id
            let cutoff = referenceDate.addingTimeInterval(-StoryReadKeys.freshWindow)
            let hasRecentVisit = place.checkIns.contains { $0.activityDate > cutoff }
            context = design == .inCard && hasRecentVisit ? .instant : .overview
            // Map entry starts at the newest visit. History remains behind the
            // place heading; opening an old place never invents a fresh story.
            sliceIndex = 0
            presentation.poi.presentNewContent()
        }
    }

    private func visitsForBrowsing(_ place: RatedPOI) -> [RatedPOI.CheckIn] {
        if context == .instant {
            // Same active window as the app. Expired visits stay in history.
            let visits = place.checkInPeople(since: referenceDate.addingTimeInterval(-StoryReadKeys.freshWindow))
                .flatMap(\.checkIns)
            guard scopedPlaceID != nil else { return visits }
            return visits.sorted {
                if $0.activityDate != $1.activityDate { return $0.activityDate > $1.activityDate }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        return place.checkIns.filter { historyPersonID == nil || $0.userId == historyPersonID }
            .sorted { $0.activityDate < $1.activityDate }
    }

    private func slices(_ place: RatedPOI) -> [Slice] {
        var places = scenario == .multiplePlaces ? fixtures : [place]
        if context == .overview || scopedPlaceID != nil {
            let placeID = scopedPlaceID ?? place.id
            places = places.filter { $0.id == placeID }
        }
        return places.flatMap { source in
            visitsForBrowsing(source).flatMap { visit -> [Slice] in
                if visit.media.isEmpty { return [Slice(place: source, visit: visit, media: nil, mediaIndex: 0)] }
                return visit.media.enumerated().map {
                    Slice(place: source, visit: visit, media: $0.element, mediaIndex: $0.offset)
                }
            }
        }
    }

    @ViewBuilder
    private func sliceBrowser(_ place: RatedPOI) -> some View {
        let pages = slices(place)
        if pages.isEmpty {
            emptyState(place, active: context == .instant)
        } else {
            let index = min(sliceIndex, pages.count - 1)
            let current = pages[index]
            ZStack {
                GeometryReader { geometry in
                    let canvasHeight = geometry.size.height + geometry.safeAreaInsets.bottom
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                          ForEach(Array(pages.enumerated()), id: \.element.id) { item in
                            Group {
                                if let media = item.element.media {
                                    fullBleedMedia(media, place: item.element.place, active: item.offset == index)
                                } else {
                                    VStack(spacing: 10) {
                                        Image(systemName: "mappin.and.ellipse").font(.system(size: 40))
                                        Text("这次没有照片或视频").font(.subheadline)
                                    }
                                    .foregroundStyle(.white.opacity(0.6))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color(white: 0.12))
                                }
                            }
                            .frame(width: geometry.size.width, height: canvasHeight)
                            .clipped().ignoresSafeArea(.container, edges: .bottom)
                            .id(item.offset)
                          }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: Binding<Int?>(get: { sliceIndex }, set: { index in
                        if let index { sliceIndex = index }
                    }))
                    .contentMargins(.all, 0, for: .scrollContent)
                    .frame(width: geometry.size.width, height: canvasHeight, alignment: .top)
                    .ignoresSafeArea(.container, edges: .bottom)
                }
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.58), location: 0),
                    .init(color: .clear, location: 0.42),
                    .init(color: .clear, location: 0.52),
                    .init(color: .black.opacity(0.68), location: 1)
                ], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    if browsingHistory {
                        Button { browsingHistory = false } label: {
                            Label("地点回看", systemImage: "chevron.left")
                                .font(.subheadline.weight(.medium)).frame(minHeight: 32)
                        }.buttonStyle(.plain)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        placeHeading(place)
                        if visiblePeople(pages).count > 1 {
                            Menu {
                                ForEach(visiblePeople(pages), id: \.self) { userID in
                                    Button(personName(userID)) {
                                        sliceIndex = pages.firstIndex { $0.visit.userId == userID } ?? 0
                                    }
                                }
                            } label: {
                                Label("\(visiblePeople(pages).count) 人", systemImage: "person.2")
                                    .font(.caption).frame(minWidth: 44, minHeight: 36)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal, 22).padding(.top, 24)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    visitFeedback(current.visit, lineLimit: isExpanded ? nil : 2)
                    HStack {
                        let visits = visitsForBrowsing(place).filter { $0.userId == current.visit.userId }
                        Text("\(context == .instant ? "近期" : "共") \(visits.count) 次到访")
                        if !current.visit.media.isEmpty {
                            Text("· 本次 \(current.mediaIndex + 1)/\(current.visit.media.count) 张／段")
                        }
                        Spacer()
                        Text("\(index + 1)/\(pages.count)").monospacedDigit()
                    }.font(.caption2).foregroundStyle(.white.opacity(0.8))
                }.padding(.horizontal, 22).padding(.bottom, 30)
            }.foregroundStyle(.white)
        }
    }

    private func visiblePeople(_ pages: [Slice]) -> [UUID] {
        var seen = Set<UUID>()
        return pages.compactMap { seen.insert($0.visit.userId).inserted ? $0.visit.userId : nil }
    }

    @ViewBuilder
    private func overview(_ place: RatedPOI) -> some View {
        if place.checkIns.isEmpty {
            emptyState(place, active: false)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    placeHeading(place)
                    Text("\(place.checkInPersonCount) 人来过 · \(place.checkIns.count) 次到访")
                        .font(.subheadline.weight(.medium))
                    personFilters(place)
                    let visits = place.checkIns.filter { historyPersonID == nil || $0.userId == historyPersonID }
                    Text(historyPersonID.map { "\(personName($0))的到访" } ?? "全部到访")
                        .font(.subheadline.weight(.semibold))
                    ForEach(visits) { visit in
                        Button { openHistory(place, personID: historyPersonID, visitID: visit.id) } label: {
                            historyRow(visit)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    if isExpanded, !place.comments.isEmpty {
                        Text("地点讨论").font(.subheadline.weight(.semibold))
                        ForEach(place.comments) { comment in
                            if case let .text(text) = comment.content {
                                Text("\(personName(comment.userId))：\(text)").font(.subheadline)
                            }
                        }
                    }
                }.padding(.horizontal, 22).padding(.top, 28).padding(.bottom, 44)
            }.scrollBounceBehavior(.basedOnSize)
        }
    }

    private func personFilters(_ place: RatedPOI) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                Button { historyPersonID = nil } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "person.2").frame(width: 36, height: 36)
                            .background(.primary.opacity(0.07), in: Circle())
                        Text("全部").font(.caption2)
                    }.opacity(historyPersonID == nil ? 1 : 0.5)
                }
                ForEach(place.checkInPeople(), id: \.userID) { person in
                    Button { historyPersonID = person.userID } label: {
                        VStack(spacing: 5) {
                            if let user = PreviewData.user(for: person.userID) { avatar(user) }
                            Text(personName(person.userID)).font(.caption2).lineLimit(1)
                            Text("\(person.checkIns.count) 次").font(.caption2).foregroundStyle(.secondary)
                        }.frame(width: 70)
                            .opacity(historyPersonID == nil || historyPersonID == person.userID ? 1 : 0.45)
                    }
                }
            }.buttonStyle(.plain)
        }
    }

    private func historyRow(_ visit: RatedPOI.CheckIn) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let user = PreviewData.user(for: visit.userId) { avatar(user) }
            VStack(alignment: .leading, spacing: 8) {
                Text(personName(visit.userId)).font(.subheadline.weight(.semibold))
                Text(visitDate(visit)).font(.caption).foregroundStyle(.secondary)
                visitFeedback(visit, lineLimit: 2)
                Text(visit.media.isEmpty ? "没有照片或视频" : "\(visit.media.count) 张照片／视频")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let media = visit.media.first { thumbnail(media).frame(width: 64, height: 64) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).padding(.top, 20)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    private func openHistory(_ place: RatedPOI, personID: UUID?, visitID: UUID? = nil) {
        historyPersonID = personID
        let pages = slices(place)
        sliceIndex = visitID.flatMap { id in pages.firstIndex { $0.visit.id == id } } ?? 0
        browsingHistory = true
    }

    private func emptyState(_ place: RatedPOI, active: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: active ? "clock" : "mappin.and.ellipse").font(.system(size: 34))
            Text(active && !place.checkIns.isEmpty ? "没有近期动态" : "这里还没有打卡").font(.headline)
            if active && !place.checkIns.isEmpty {
                Text("\(place.checkIns.count) 次历史到访仍在地点里").font(.subheadline).foregroundStyle(.secondary)
                Button("看地点历史") { contextSelection.wrappedValue = .overview }.buttonStyle(.bordered)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeHeading(_ place: RatedPOI) -> some View {
            HStack(spacing: 12) {
                Image(systemName: place.poi.category.symbolName)
                    .font(.system(size: 21, weight: .medium)).foregroundStyle(place.poi.category.accentColor)
                    .frame(width: 44, height: 44)
                    .background(place.poi.category.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text(place.poi.name).font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text(place.poi.category.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
    }

    private func info(_ place: RatedPOI) -> ExperienceDetailView.POIInfoModel {
        .init(name: place.poi.name, category: place.poi.category,
              endorsementBadges: ExperienceDetailView.poiEndorsementBadges(for: place),
              placeID: place.id)
    }

    private func stats(_ place: RatedPOI) -> ExperienceDetailView.POIStatsModel {
        .init(checkIns: place.checkInPersonCount, comments: place.comments.count,
              favorites: place.favoritesCount, endorsements: place.endorsements)
    }

    private func contributors(_ place: RatedPOI) -> [ExperienceDetailView.POIStoryContributor] {
        place.checkInPeople().map { person in
            .init(id: person.userID, userId: person.userID, user: originalUserProvider(person.userID),
                  items: person.checkIns.flatMap { visit -> [ExperienceDetailView.POIStoryContributor.Item] in
                      // Location-only fixtures remain playable without borrowing
                      // an older visit's photo or dropping the person entirely.
                      if visit.media.isEmpty {
                          return [.init(id: visit.id,
                              media: .init(id: visit.id, content: .emoji("📍")),
                              timestamp: visit.activityDate, readKey: "preview-\(visit.id)-location")]
                      }
                      return visit.media.map { media in
                          .init(id: media.id, media: mediaItem(media), timestamp: visit.activityDate,
                                readKey: "preview-\(visit.id)-\(media.id)")
                      }
                  }, mostRecent: person.latest.activityDate)
        }
    }

    private func personName(_ id: UUID) -> String {
        id == PreviewData.currentUser.id ? "我" : "@\(originalUserProvider(id)?.handle ?? "朋友")"
    }

    private func visitDate(_ visit: RatedPOI.CheckIn) -> String {
        visit.activityDate.formatted(.dateTime.year().month().day().hour().minute())
    }

    private func avatar(_ user: User) -> some View {
        MapImage(url: user.avatarURL) { phase in
            if case let .success(image) = phase { image.resizable().scaledToFill() }
            else { Circle().fill(.gray.opacity(0.2)) }
        }.frame(width: 34, height: 34).clipShape(Circle())
    }

    @ViewBuilder
    private func visitFeedback(_ visit: RatedPOI.CheckIn, lineLimit: Int?) -> some View {
        if visit.endorsement != nil || visit.comment != nil {
            HStack(alignment: .top, spacing: 8) {
                if let rating = visit.endorsement { POIFeedbackIcon(endorsement: rating, set: .emoji, size: 23) }
                if let comment = visit.comment { Text(comment).font(.subheadline).lineLimit(lineLimit) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mediaItem(_ media: RatedPOI.Media) -> MediaDisplayItem {
        switch media.kind {
        case let .photo(url): .init(id: media.id, content: .photo(url))
        case let .video(url, poster): .init(id: media.id, content: .video(url: url, poster: poster, metadata: nil))
        }
    }

    private func fullBleedMedia(_ media: RatedPOI.Media, place: RatedPOI, active: Bool) -> some View {
        GeometryReader { geometry in
            ExperienceDetailView.MediaCardView(item: mediaItem(media),
                accentColor: place.poi.category.accentColor, mode: .card,
                isPlaybackActive: active, usesAspectFit: false, blendsWithBackground: true)
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }

    private func thumbnail(_ media: RatedPOI.Media) -> some View {
        let url: URL?
        let isVideo: Bool
        switch media.kind {
        case let .photo(photo): url = photo; isVideo = false
        case let .video(_, poster): url = poster; isVideo = true
        }
        return Color.gray.opacity(0.12)
            .overlay {
                MapImage(url: url) { phase in
                    if case let .success(image) = phase { image.resizable().scaledToFill() }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                if isVideo {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2)
                }
            }
    }
}
#endif
