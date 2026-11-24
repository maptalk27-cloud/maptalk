import SwiftUI

/// The overview owns a place's permitted, already-loaded history, not the
/// homepage's recent-story window. Opening a person never replaces that source.
struct POIPlaceOverviewStyle: ViewModifier {
    let place: RatedPOI
    let userProvider: (UUID) -> User?
    var isExpanded = false
    var isEnabled = true
    var onUserSelected: (User) -> Void = { _ in }
    var onContributorViewed: ([String]) -> Void = { _ in }
    var isContributorUnseen: ([String]) -> Bool = { _ in true }

    @Environment(\.appEnv) private var environment
    @Environment(\.friendStoryChildPresentationChanged) private var childPresentationChanged
    @Environment(\.friendStoryPlaybackEnabled) private var parentPlaybackEnabled
    @State private var playback: Playback?
    @State private var deferredProfile: User?
    @State private var showsMediaUnavailable = false
    @State private var childPresentationID = UUID()
    @Namespace private var transition

    private struct Playback: Identifiable {
        let id = UUID()
        let contributors: [ExperienceDetailView.POIStoryContributor]
        let index: Int
        let source: ExperienceDetailView.POIRecentSharersRow.TransitionID
        let accentColor: Color
        let visitIDs: Set<UUID>
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .environment(\.experiencePOIPlaceHeader, { id in
                    guard id == place.id else { return nil }
                    return AnyView(POIStoryPlaceHeading(place: place))
                })
                .environment(\.experiencePOIVisitorSummary, visitorSummary)
                .environment(\.experiencePOIFootprintsVisible, false)
                .environment(\.experiencePOIHistoryVisible, true)
                .environment(\.experiencePOIPlaybackActions, nil)
                .environment(\.experiencePOIHeaderActions, nil)
                .environment(\.colorScheme, .dark)
                .environment(\.friendStoryPlaybackEnabled, parentPlaybackEnabled && playback == nil)
                .fullScreenCover(item: $playback, onDismiss: finishPlayback) { session in
                    ExperienceDetailView.POIStoryViewer(
                        contributors: session.contributors,
                        initialIndex: session.index,
                        accentColor: session.accentColor,
                        onUserSelected: { user in
                            deferredProfile = user
                            playback = nil
                        },
                        onPageViewed: { onContributorViewed([$0]) },
                        usesQuietChrome: true,
                        onClose: { playback = nil }
                    )
                    // Only the selected avatar participates in the transition.
                    // Keep appearance local so the underlying map cannot flash.
                    .environment(\.colorScheme, .dark)
                    .environment(\.friendStoryExpectedMedia, [])
                    .environment(\.friendStoryOnMediaReady, nil)
                    .environment(\.friendStoryPlaybackEnabled, true)
                    .environment(\.friendStoryChildPresentationChanged, nil)
                    .environment(\.postPlaceChromeIDs, [])
                    .navigationTransition(.zoom(sourceID: session.source, in: transition))
                }
                .onChangeCompat(of: playback != nil) { presented in
                    childPresentationChanged?(childPresentationID, presented)
                }
                .onChangeCompat(of: place.id) { _ in playback = nil }
                .onChangeCompat(of: Set(place.checkIns.map(\.id))) { allowedIDs in
                    if let playback, !playback.visitIDs.isSubset(of: allowedIDs) {
                        self.playback = nil
                    }
                }
                .alert("Media isn't ready yet", isPresented: $showsMediaUnavailable) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Please try again after this person's photos and videos finish loading.")
                }
                .onDisappear {
                    if playback == nil { childPresentationChanged?(childPresentationID, false) }
                }
        } else {
            content
        }
    }

    private var visitorSummary: AnyView {
        let people = place.checkInPeople()
        let contributors = POIPlaceHistoryPresentation.contributors(
            for: place, userProvider: userProvider)
        let counts = Dictionary(uniqueKeysWithValues: people.map { ($0.userID, $0.checkIns.count) })
        let loadingUsers = Set(people.filter { person in
            guard let backend = environment.backend else { return false }
            return person.checkIns.contains { !backend.hasPreparedMedia(for: $0.id) }
        }.map(\.userID))
        return AnyView(ExperienceDetailView.POIRecentSharersRow(
            sharers: contributors,
            accentColor: place.poi.category.accentColor,
            isContributorUnseen: isContributorUnseen,
            onSelect: { index in
                guard contributors.indices.contains(index) else { return }
                let personID = contributors[index].userId
                guard !loadingUsers.contains(personID) else {
                    showsMediaUnavailable = true
                    return
                }
                // Never freeze an undownloaded visit as a location-only page.
                // Download completion can precede the parent's next projection.
                // Adopt bytes only for the original visible visits at tap time.
                let snapshot = environment.backend?.cachedSnapshot(for: place.checkIns.map(\.id))
                let playbackPlace = ExperienceDetailView.mergingMedia(into: place,
                    from: snapshot?.pois.first(where: { $0.id == place.id }))
                let ready = POIPlaceHistoryPresentation.contributors(for: playbackPlace,
                    userProvider: userProvider).filter { !loadingUsers.contains($0.userId) }
                guard let readyIndex = ready.firstIndex(where: { $0.userId == personID }) else { return }
                let readyUsers = Set(ready.map(\.userId))
                playback = Playback(contributors: ready, index: readyIndex,
                    source: .init(placeID: place.id, userID: personID),
                    accentColor: place.poi.category.accentColor,
                    visitIDs: Set(place.checkIns.filter { readyUsers.contains($0.userId) }.map(\.id)))
            },
            wraps: isExpanded,
            visitCounts: counts,
            loadingUserIDs: loadingUsers,
            transitionNamespace: transition,
            transitionPlaceID: place.id
        )
        .padding(.horizontal,
            ExperienceDetailView.ExperienceSheetLayout.engagementHorizontalInset
                - ExperienceDetailView.POIHeroLayout.collapsedHorizontalPadding))
    }

    private func finishPlayback() {
        childPresentationChanged?(childPresentationID, false)
        if let user = deferredProfile {
            deferredProfile = nil
            onUserSelected(user)
        }
    }
}

enum POIPlaceHistoryPresentation {
    /// Only use the supplied visibility-scoped projection. No global/private
    /// lookup, age filter, or borrowed media is allowed here.
    static func contributors(for place: RatedPOI,
                             userProvider: (UUID) -> User?) -> [ExperienceDetailView.POIStoryContributor] {
        place.checkInPeople().map { person in
            .init(id: person.userID, userId: person.userID, user: userProvider(person.userID),
                  items: person.checkIns.flatMap { visit in
                      if visit.media.isEmpty {
                          return [ExperienceDetailView.POIStoryContributor.Item(
                              id: visit.id, media: .init(id: visit.id, content: .emoji("📍")),
                              timestamp: visit.activityDate,
                              readKey: StoryReadKeys.poiVisit(poiId: place.id,
                                  checkInId: visit.id, timestamp: visit.activityDate))]
                      }
                      return visit.media.map { media in
                          let content: ExperienceDetailView.MediaDisplayItem.Content
                          switch media.kind {
                          case let .photo(url): content = .photo(url)
                          case let .video(url, poster): content = .video(url: url, poster: poster, metadata: nil)
                          }
                          return ExperienceDetailView.POIStoryContributor.Item(
                              id: media.id, media: .init(id: media.id, content: content),
                              timestamp: visit.activityDate,
                              readKey: StoryReadKeys.poiStoryPage(poiId: place.id,
                                  checkInId: visit.id, mediaId: media.id, timestamp: visit.activityDate))
                      }
                  }, mostRecent: person.latest.activityDate)
        }
    }
}
