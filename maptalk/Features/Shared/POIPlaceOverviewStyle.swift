import Combine
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback: Playback?
    @State private var preparation: Preparation?
    @State private var isVisible = false
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

    private struct Preparation: Identifiable {
        let id = UUID()
        let place: RatedPOI
        let personID: UUID
        let visitIDs: [UUID]
        let revision: Int
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .environment(\.experiencePOIPlaceHeader, { id in
                    guard id == place.id else { return nil }
                    return AnyView(POIStoryPlaceHeading(place: place,
                        trailingAction: AnyView(POIStorySaveButton(place: place))))
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
                .onAppear { isVisible = true }
                .task(id: preparation?.id) {
                    guard let preparation else { return }
                    await preparePlayback(preparation)
                }
                .onChangeCompat(of: place.id) { _ in
                    preparation = nil
                    playback = nil
                }
                .onChangeCompat(of: Set(place.checkIns.map(\.id))) { allowedIDs in
                    if let preparation,
                       !Set(preparation.place.checkIns.map(\.id)).isSubset(of: allowedIDs) {
                        self.preparation = nil
                    }
                    if let playback, !playback.visitIDs.isSubset(of: allowedIDs) {
                        self.playback = nil
                    }
                }
                .onChangeCompat(of: parentPlaybackEnabled) { enabled in
                    if !enabled { preparation = nil }
                }
                .onChangeCompat(of: scenePhase) { phase in
                    if phase != .active { preparation = nil }
                }
                .onReceive(environment.backend?.publicContentChanges.eraseToAnyPublisher()
                    ?? Empty<Set<UUID>, Never>().eraseToAnyPublisher()) { _ in
                    // The pending bytes and frozen viewer belong to one access
                    // revision; never present a result from a revoked scope.
                    preparation = nil
                    playback = nil
                }
                .alert("Media isn't ready yet", isPresented: $showsMediaUnavailable) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Couldn't finish loading this person's media. Tap their avatar to retry.")
                }
                .onDisappear {
                    isVisible = false
                    preparation = nil
                    if playback == nil { childPresentationChanged?(childPresentationID, false) }
                }
        } else {
            content
        }
    }

    private var visitorSummary: AnyView {
        let people = place.checkInPeople()
        if let backend = environment.backend {
            return AnyView(POIPlaceVisitCountObserver(backend: backend, placeID: place.id,
                ownerIDs: people.map(\.userID)) { counts in
                visitorSummary(visitCounts: counts)
            })
        }
        return visitorSummary(visitCounts: Dictionary(uniqueKeysWithValues:
            people.map { ($0.userID, $0.visitDayCount) }))
    }

    private func visitorSummary(visitCounts: [UUID: Int]) -> AnyView {
        let contributors = POIPlaceHistoryPresentation.contributors(
            for: place, userProvider: userProvider)
        let loadingUsers: Set<UUID> = preparation.map { [$0.personID] } ?? []
        return AnyView(ExperienceDetailView.POIRecentSharersRow(
            sharers: contributors,
            accentColor: place.poi.category.accentColor,
            isContributorUnseen: isContributorUnseen,
            onSelect: { index in
                guard contributors.indices.contains(index), preparation == nil,
                      playback == nil, isVisible, parentPlaybackEnabled, scenePhase == .active else { return }
                openContributor(contributors[index].userId)
            },
            wraps: isExpanded,
            visitCounts: visitCounts,
            loadingUserIDs: loadingUsers,
            transitionNamespace: transition,
            transitionPlaceID: place.id
        )
        .padding(.horizontal,
            ExperienceDetailView.ExperienceSheetLayout.engagementHorizontalInset
                - ExperienceDetailView.POIHeroLayout.collapsedHorizontalPadding))
    }

    private func openContributor(_ personID: UUID) {
        let ids = place.checkIns.filter { $0.userId == personID }.map(\.id)
        guard !ids.isEmpty else { return }
        guard let backend = environment.backend,
              ids.contains(where: { !backend.hasPreparedMedia(for: $0) }) else {
            presentPlayback(for: personID, in: place)
            return
        }
        // Only an explicit avatar tap starts video preparation. Freeze the
        // permitted loaded scope now; pagination cannot widen this request.
        preparation = .init(place: place, personID: personID, visitIDs: ids,
                            revision: backend.publicContentRevision)
    }

    private func preparePlayback(_ request: Preparation) async {
        guard let backend = environment.backend else { return }
        do {
            _ = try await backend.ensureMedia(for: request.visitIDs)
            guard !Task.isCancelled, preparation?.id == request.id else { return }
            guard isVisible, parentPlaybackEnabled, scenePhase == .active,
                  request.revision == backend.publicContentRevision else {
                preparation = nil
                return
            }
            preparation = nil
            presentPlayback(for: request.personID, in: request.place)
        } catch {
            guard !Task.isCancelled, preparation?.id == request.id else { return }
            preparation = nil
            showsMediaUnavailable = true
        }
    }

    private func presentPlayback(for personID: UUID, in scopedPlace: RatedPOI) {
        // Other already-ready contributors retain their existing place-viewer
        // positions. Opening this person never downloads any of their media.
        let readyUsers = Set(scopedPlace.checkInPeople().filter { person in
            guard let backend = environment.backend else { return true }
            return person.checkIns.allSatisfy { backend.hasPreparedMedia(for: $0.id) }
        }.map(\.userID))
        guard readyUsers.contains(personID) else {
            showsMediaUnavailable = true
            return
        }
        let snapshot = environment.backend?.cachedSnapshot(for: scopedPlace.checkIns.map(\.id))
        let playbackPlace = ExperienceDetailView.mergingMedia(into: scopedPlace,
            from: snapshot?.pois.first(where: { $0.id == scopedPlace.id }))
        let ready = POIPlaceHistoryPresentation.contributors(for: playbackPlace,
            userProvider: userProvider).filter { readyUsers.contains($0.userId) }
        guard let index = ready.firstIndex(where: { $0.userId == personID }) else { return }
        playback = Playback(contributors: ready, index: index,
            source: .init(placeID: scopedPlace.id, userID: personID),
            accentColor: scopedPlace.poi.category.accentColor,
            visitIDs: Set(scopedPlace.checkIns.filter { readyUsers.contains($0.userId) }.map(\.id)))
    }

    private func finishPlayback() {
        childPresentationChanged?(childPresentationID, false)
        if let user = deferredProfile {
            deferredProfile = nil
            onUserSelected(user)
        }
    }
}

/// Observe authoritative totals separately from the place projection. A count
/// response must update this row even when no visit/media payload has changed.
private struct POIPlaceVisitCountObserver<Content: View>: View {
    @ObservedObject var backend: BackendStore
    let placeID: UUID
    let ownerIDs: [UUID]
    @ViewBuilder let content: ([UUID: Int]) -> Content
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.friendStoryPlaybackEnabled) private var playbackEnabled
    @State private var isVisible = false
    @State private var contentRevision = 0

    private struct Request: Equatable {
        let placeID: UUID
        let ownerIDs: [UUID]
        let revision: Int
    }

    private var request: Request? {
        guard isVisible, playbackEnabled, scenePhase == .active else { return nil }
        return Request(placeID: placeID, ownerIDs: ownerIDs,
                       revision: contentRevision + backend.poiVisitCountRevision)
    }

    var body: some View {
        let counts = Dictionary(ownerIDs.compactMap { ownerID -> (UUID, Int)? in
            guard let count = backend.visiblePOIVisitDayCount(placeID: placeID, authorID: ownerID) else {
                return nil
            }
            return (ownerID, count)
        }, uniquingKeysWith: { first, _ in first })
        content(counts)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onReceive(backend.publicContentChanges) { _ in contentRevision &+= 1 }
            .task(id: request) {
                guard let request else { return }
                await backend.ensurePOIVisitDayCounts(placeID: request.placeID, ownerIDs: request.ownerIDs)
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
