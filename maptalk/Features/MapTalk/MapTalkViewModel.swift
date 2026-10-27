import Combine
import CoreLocation
import Foundation
import MapKit

/// One consumer-facing landmark choice. Public directory data, friends'
/// public check-ins, and the person's private MyMap copy are provenance for
/// the same place, not three duplicate rows in the picker.
struct MapTalkNearbyPlaceOption: Identifiable {
    let place: RatedPOI
    let distanceMeters: CLLocationDistance
    let isPublicDirectoryPlace: Bool
    let isInMyMap: Bool
    let friendUsers: [User]
    /// Distinct people in public check-ins. This intentionally excludes the
    /// person's private MyMap history.
    let publicVisitorCount: Int

    var id: UUID { place.id }
}

@MainActor
final class MapTalkViewModel: ObservableObject {
    enum Scope {
        case global
        case user(User)
    }

    enum Mode: Int {
        case world
        case friends

        init(index: Int) {
            self = index == 1 ? .friends : .world
        }
    }

    @Published var mode: Mode = .world
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33),
        span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
    )
    @Published var ratedPOIs: [RatedPOI] = []
    @Published var reals: [RealPost] = []
    /// Stable public feed snapshots. Camera movement, selection and read state
    /// never rebuild these arrays; only feed sources or an explicit expiry do.
    @Published private(set) var activeFeedItems: [RealStoriesRow.StoryItem] = []
    @Published private(set) var activeFeedPOIs: [RatedPOI] = []
    @Published private(set) var activeFeedReels: [RealPost] = []
    @Published private(set) var activityPOIs: [RatedPOI] = []
    @Published private(set) var activityReels: [RealPost] = []
    @Published var userCoordinate: CLLocationCoordinate2D?
    /// The unprojected device reading is kept alongside the coordinate so a
    /// publish can reject a stale or invalid location instead of silently
    /// falling back to wherever the map happened to be browsing.
    @Published private(set) var liveLocation: CLLocation?
    @Published private(set) var locationAuthorization: CLAuthorizationStatus
    @Published private(set) var isLoadingNearbyPlaces = true

    let scope: Scope
    @Published private(set) var friendFootprints: [MapTalkFriendFootprint] = []
    private let previewFootprints: [MapTalkFriendFootprint]
    private let environment: AppEnvironment
    private let mapSearchRegion = PassthroughSubject<MKCoordinateRegion, Never>()
    private let nearbyPlaceRefresh = PassthroughSubject<CLLocationCoordinate2D, Never>()
    private var backendMapSearch: Task<Void, Never>?
    private var lastBackendMapRegion: MKCoordinateRegion?
    @Published private(set) var withdrawnPublicMemoryIDs: Set<UUID> = []
    private var freshnessDate = Date.now
    private var repositoryPOIs: [RatedPOI] = []
    private var nearbySocialPOIs: [RatedPOI] = []
    private var repositoryActivePOIs: [RatedPOI] = []
    @Published private var nearbyDirectoryPOIs: [RatedPOI] = []
    private var repositoryMapReels: [RealPost] = []
    private var repositoryActiveReels: [RealPost] = []
    private var publishedPOIOverlays: [RatedPOI] = []
    private var publishedReelOverlays: [RealPost] = []
    private var shouldCenterWhenLocationArrives = false
    private var shouldApplyInitialLocation = false
    private var lastVisibleRegion: MKCoordinateRegion?
    private var retainedActiveFeedItemID: UUID?
    private var activeFeedExpiryWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    init(environment: AppEnvironment, scope: Scope = .global) {
        self.environment = environment
        self.scope = scope
        previewFootprints = environment.backend == nil && environment.build.featureFlags.contains(.mock)
            ? MapTalkFriendFootprint.previewData : []
        locationAuthorization = environment.location.authorization.value
        if !environment.build.featureFlags.contains(.mock) {
            region = MapStartupLocation.worldRegion
            if case .global = scope {
                if let location = MapStartupLocation.usable(environment.location.location.value) {
                    region = MapStartupLocation.region(around: location.coordinate)
                } else {
                    shouldApplyInitialLocation = true
                }
            }
        }
        switch scope {
        case .global:
            friendFootprints = previewFootprints
            bind()
        case let .user(user):
            friendFootprints = []
            loadUserScope(for: user)
        }
        environment.backend?.publicContentChanges
            .sink { [weak self] ids in self?.withdrawPublicMemories(ids) }
            .store(in: &cancellables)
    }

    private func withdrawPublicMemories(_ ids: Set<UUID>) {
        // Search-render records are separate from the feed. Remove the exact
        // withdrawn visits immediately, before fetching the current viewport.
        withdrawnPublicMemoryIDs.formUnion(ids)
        backendMapSearch?.cancel()
        repositoryPOIs = BackendStore.removingMemories(ids, from: repositoryPOIs)
        nearbySocialPOIs = BackendStore.removingMemories(ids, from: nearbySocialPOIs)
        repositoryActivePOIs = BackendStore.removingMemories(ids, from: repositoryActivePOIs)
        publishedPOIOverlays = BackendStore.removingMemories(ids, from: publishedPOIOverlays)
        repositoryMapReels.removeAll { ids.contains($0.id) }
        repositoryActiveReels.removeAll { ids.contains($0.id) }
        publishedReelOverlays.removeAll { ids.contains($0.id) }
        retainedActiveFeedItemID = nil
        rebuildMapRenderContent()
        switch scope {
        case .global:
            rebuildActiveFeed(asOf: .now)
            searchMap(in: lastBackendMapRegion ?? region)
        case let .user(user):
            activeFeedPOIs = BackendStore.removingMemories(ids, from: activeFeedPOIs)
            activeFeedReels.removeAll { ids.contains($0.id) }
            activityPOIs = activeFeedPOIs
            activityReels = activeFeedReels
            activeFeedItems = MapStoryFeed.items(reals: activeFeedReels, ratedPOIs: activeFeedPOIs,
                onlyRecentPOIStories: false, userProvider: self.user(for:), now: .now)
            loadUserScope(for: user, updateRegion: false)
        }
    }

    func onAppear() {
        if case .global = scope {
            environment.location.requestWhenInUse()
            searchMap(in: lastVisibleRegion ?? region)
            refreshFreshness()
            if let backend = environment.backend {
                Task { do { try await backend.refreshIfNeeded() } catch {
                    if backend.isActive && !(error is CancellationError) { backend.issue = error.localizedDescription }
                } }
            }
        }
    }

    /// Refresh both map layers together, including after a long background stay.
    /// Keeping one clock for the snapshot avoids a marker changing mid-tap.
    func refreshFreshness(asOf now: Date = .now) {
        guard case .global = scope else { return }
        // Retention only bridges an expiry while someone is reading the card.
        // Reopening the app after a long background stay must not carry that
        // temporary exception into a new browsing session.
        if let retainedActiveFeedItemID,
           let retained = activeFeedItems.first(where: { $0.id == retainedActiveFeedItemID }) {
            let remainsActive: Bool
            switch retained.source {
            case let .real(real):
                remainsActive = StoryReadKeys.isActive(real, asOf: now)
            case let .poi(group):
                remainsActive = hasRecentVisit(group.ratedPOI, asOf: now)
            case .journey:
                remainsActive = StoryReadKeys.isFresh(retained.timestamp, asOf: now)
            }
            if !remainsActive { self.retainedActiveFeedItemID = nil }
        }
        rebuildActiveFeed(asOf: now)
    }

    /// Search-render input follows the map camera. It is intentionally
    /// independent from the device coordinate and the top active feed.
    func searchMap(in region: MKCoordinateRegion) {
        guard case .global = scope else { return }
        if let backend = environment.backend {
            lastBackendMapRegion = region
            backendMapSearch?.cancel()
            let revision = backend.publicContentRevision
            backendMapSearch = Task { [weak self] in
                do {
                    let apply: (BackendStore.Snapshot) -> Void = { [weak self] content in
                        guard let self, !Task.isCancelled, backend.isActive,
                              revision == backend.publicContentRevision else { return }
                        repositoryPOIs = content.pois
                        repositoryMapReels = content.reels
                        rebuildMapRenderContent()
                    }
                    let content = try await backend.loadMap(region, onUpdate: apply)
                    try Task.checkCancellation()
                    apply(content)
                } catch {
                    if Task.isCancelled == false, backend.isActive { backend.issue = error.localizedDescription }
                }
            }
            return
        }
        mapSearchRegion.send(region)
    }

    /// A feed item can be selected before the camera search response arrives.
    /// Retain that one canonical place so focusing it never lands on an empty
    /// map; closing or selecting another item releases it naturally.
    func mapRenderPOIs(
        retaining selectedID: UUID?,
        selectedMapPOI: RatedPOI? = nil
    ) -> [RatedPOI] {
        var result = mergePOIs(
            preferred: activeFeedPOIs,
            fallback: ratedPOIs.filter { isUserScope || hasRecentVisit($0, asOf: freshnessDate) }
        )
        if let selectedID,
           let selectedMapPOI,
           selectedMapPOI.id == selectedID,
           isUserScope || hasRecentVisit(selectedMapPOI, asOf: freshnessDate) {
            let remaining = removingWithdrawnVisits(from: selectedMapPOI)
            if let remaining {
                result = mergePOIs(preferred: [remaining], fallback: result)
            }
        }
        return result.compactMap { removingUnavailableMapVisits(from: $0) }
            .filter { isUserScope || hasRecentVisit($0, asOf: freshnessDate) }
    }

    func mapRenderReels(
        retaining selectedID: UUID?,
        selectedMapReel: RealPost? = nil
    ) -> [RealPost] {
        var result = merge(activeFeedReels, with: reals)
        if let selectedID,
           let selectedMapReel,
           selectedMapReel.id == selectedID,
           !withdrawnPublicMemoryIDs.contains(selectedMapReel.id) {
            result = merge([selectedMapReel], with: result)
        }
        return result.filter { !unavailableMapMemoryIDs.contains($0.id) }
    }

    private var unavailableMapMemoryIDs: Set<UUID> {
        guard case .global = scope else { return withdrawnPublicMemoryIDs }
        return withdrawnPublicMemoryIDs.union(environment.backend?.excludedMapMemoryIDs ?? [])
    }

    private func removingUnavailableMapVisits(from place: RatedPOI) -> RatedPOI? {
        let ids = unavailableMapMemoryIDs
        guard place.checkIns.contains(where: { ids.contains($0.id) }) else { return place }
        return BackendStore.removingMemories(ids, from: [place]).first
    }

    func removingWithdrawnVisits(from place: RatedPOI) -> RatedPOI? {
        guard place.checkIns.contains(where: { withdrawnPublicMemoryIDs.contains($0.id) }) else { return place }
        return BackendStore.removingMemories(withdrawnPublicMemoryIDs, from: [place]).first
    }

    private func hasRecentVisit(_ place: RatedPOI, asOf now: Date) -> Bool {
        place.checkIns.contains { StoryReadKeys.isFresh($0.activityDate, asOf: now) }
    }

    /// Keep the currently opened feed item stable if its TTL crosses while
    /// the card is on screen. It leaves the normal feed as soon as the user
    /// closes or chooses another context.
    func retainActiveFeedItem(id: UUID) {
        guard activeFeedItems.contains(where: { $0.id == id }) else { return }
        let previousID = retainedActiveFeedItemID
        guard previousID != id else { return }
        retainedActiveFeedItemID = id
        if previousID != nil {
            rebuildActiveFeed(asOf: .now)
        }
    }

    func releaseRetainedActiveFeedItem() {
        guard retainedActiveFeedItemID != nil else { return }
        retainedActiveFeedItemID = nil
        rebuildActiveFeed(asOf: .now)
    }

    func centerOnUser() {
        shouldApplyInitialLocation = false
        guard let location = MapStartupLocation.usable(environment.location.location.value) else {
            shouldCenterWhenLocationArrives = true
            environment.location.requestWhenInUse()
            return
        }
        shouldCenterWhenLocationArrives = false
        centerRegion(on: location.coordinate)
    }

    private func centerRegion(on coordinate: CLLocationCoordinate2D) {
        let visibleSpan = (lastVisibleRegion ?? region).span
        // Before the first fix the neutral world camera is only a placeholder,
        // not a zoom level the locate button should preserve.
        let span = visibleSpan.latitudeDelta >= 90
            ? MapStartupLocation.region(around: coordinate).span : visibleSpan
        region = MKCoordinateRegion(center: coordinate, span: span)
    }

    /// A late GPS update must never pull the camera away after the person has
    /// started browsing or selected a story. The locate button can opt in again.
    func cancelPendingLocationFocus() {
        shouldApplyInitialLocation = false
        shouldCenterWhenLocationArrives = false
    }

    func rememberVisibleRegion(_ region: MKCoordinateRegion) {
        lastVisibleRegion = region
    }

    func user(for id: UUID) -> User? {
        // A profile-scoped map may have been opened with an older identity.
        // Keep its cards in sync with the server-backed username and avatar.
        if let current = environment.backend?.user(for: id) { return current }
        if case let .user(user) = scope, user.id == id {
            return user
        }
        return environment.user(for: id)
    }

    /// MapTalk exposes only snapshots attached to public Reels. Private Bubble
    /// snapshots remain reachable from MyMap through its own provider.
    func journey(for id: UUID) -> JourneyPost? {
        if environment.backend != nil { return nil }
        return environment.myMapArchive.publicBubbleCatalog.first { $0.id == id }
            ?? environment.myMapArchive.legacyJourneyCatalog.first { $0.id == id }
            ?? PreviewData.journey(for: id)
    }

    var isUserScope: Bool {
        if case .user = scope {
            return true
        }
        return false
    }

    var scopedUser: User? {
        if case let .user(user) = scope {
            return user
        }
        return nil
    }

    /// Keep the last accuracy-bearing device reading while Core Location
    /// refreshes in the background. A stationary device (and especially a
    /// Simulator fixed location) may not emit a new sample every few seconds;
    /// expiring the value by timestamp made the composer fall back to an
    /// endless "Locating" state even though its nearby results were valid.
    var publishableLiveLocation: CLLocation? {
        guard let liveLocation,
              liveLocation.horizontalAccuracy >= 0 else {
            return nil
        }
        return liveLocation
    }

    func publishLocation(for _: MapTalkPublishDestination) -> CLLocation? {
        publishableLiveLocation
    }

    /// Opening the composer retries Maps even if the person has not moved
    /// since an earlier network failure. It never changes the map or GPS fix.
    func refreshNearbyPlaces() {
        guard let location = publishableLiveLocation else { return }
        nearbyPlaceRefresh.send(location.coordinate)
    }

    func region(for real: RealPost) -> MKCoordinateRegion {
        regionAround(
            coordinate: real.center,
            radiusMeters: real.radiusMeters,
            minimumRadius: 3_500
        )
    }

    func focus(on real: RealPost) {
        cancelPendingLocationFocus()
        region = region(for: real)
    }

    func region(for rated: RatedPOI) -> MKCoordinateRegion {
        regionAround(
            coordinate: rated.poi.coordinate,
            radiusMeters: 650,
            minimumRadius: 1_800
        )
    }

    func focus(on rated: RatedPOI) {
        cancelPendingLocationFocus()
        region = region(for: rated)
    }

    func region(for journey: JourneyPost) -> MKCoordinateRegion {
        regionAround(
            coordinate: journey.coordinate,
            radiusMeters: 2_200,
            minimumRadius: 2_200
        )
    }

    func focus(on journey: JourneyPost) {
        cancelPendingLocationFocus()
        region = region(for: journey)
    }

    /// The POI's content belongs to a check-in, rather than becoming a second
    /// standalone landmark. Selecting an existing landmark therefore adds one
    /// new check-in to that POI; it never creates a duplicate pin.
    @discardableResult
    func publishPlace(
        _ draft: MapTalkPlaceDraft,
        at location: CLLocation,
        audience: MapPublishAudience
    ) -> RatedPOI? {
        let hasMedia = draft.media != nil
        let newCheckIn = RatedPOI.CheckIn(
            userId: environment.myMapArchive.currentUserID,
            endorsement: hasMedia ? .solid : nil,
            media: draft.media.map { [$0] } ?? [],
            tag: hasMedia ? .explore : nil
        )

        let privatePlace: RatedPOI
        let publicPlace: RatedPOI?
        switch draft.target {
        case let .existing(existing):
            let landmarkLocation = CLLocation(
                latitude: existing.poi.coordinate.latitude,
                longitude: existing.poi.coordinate.longitude
            )
            // A person can select a sparse-list fallback, so submission uses
            // the same hard ceiling as the picker rather than its usual
            // tighter radius.
            guard landmarkLocation.distance(from: location) <= POISelectionPolicy.radius(for: existing.poi.directoryKind) else {
                return nil
            }

            privatePlace = appending(newCheckIn, to: existing)
            publicPlace = audience == .livePublic
                ? appending(
                    newCheckIn,
                    to: publicPOI(withID: existing.id)
                        ?? emptyPublicPOI(for: existing.poi)
                )
                : nil

        case let .new(name, category):
            let poi = POI(
                id: UUID(),
                name: name,
                coordinate: location.coordinate,
                category: category
            )
            let created = RatedPOI(
                poi: poi,
                highlight: nil,
                secondary: "Added by you",
                media: [],
                checkIns: [newCheckIn],
                comments: [],
                endorsements: .init(hype: 0, solid: hasMedia ? 1 : 0, meh: 0, questionable: 0),
                tags: hasMedia ? [.init(tag: .explore, count: 1)] : [],
                isFavoritedByCurrentUser: true,
                favoritesCount: 1
            )
            privatePlace = created
            publicPlace = audience == .livePublic
                ? RatedPOI(
                    poi: poi,
                    highlight: nil,
                    secondary: nil,
                    media: [],
                    checkIns: [newCheckIn],
                    comments: [],
                    endorsements: .init(
                        hype: 0,
                        solid: hasMedia ? 1 : 0,
                        meh: 0,
                        questionable: 0
                    ),
                    tags: hasMedia ? [.init(tag: .explore, count: 1)] : [],
                    isFavoritedByCurrentUser: false,
                    favoritesCount: 0
                )
                : nil
        }

        return environment.myMapArchive.savePOI(
            privatePlace,
            publicVersion: publicPlace,
            audience: audience
        )
    }

    @discardableResult
    func publishReel(
        _ draft: MapTalkReelDraft,
        at location: CLLocation,
        audience: MapPublishAudience
    ) -> RealPost? {
        let now = Date.now
        let bubble = draft.bubbleSource.flatMap {
            makeBubbleSnapshot(
                from: $0,
                at: location.coordinate,
                createdAt: now,
                audience: audience
            )
        }
        guard draft.bubbleSource == nil || bubble != nil else { return nil }

        let reel = RealPost(
            id: UUID(),
            userId: environment.myMapArchive.currentUserID,
            center: location.coordinate,
            radiusMeters: 220,
            message: draft.text.isEmpty ? nil : draft.text,
            // The composer already caps selection at nine. Keep the model
            // boundary defensive so future callers cannot create an
            // unexpectedly heavy map Reel.
            attachments: Array(draft.attachments.prefix(9)),
            capsuleId: bubble?.id,
            likes: [],
            comments: [],
            visibility: audience == .livePublic ? .publicAll : .privateOnly,
            createdAt: now,
            expiresAt: now.addingTimeInterval(StoryReadKeys.freshWindow)
        )

        if let bubble {
            environment.myMapArchive.saveBubble(bubble, audience: audience)
        }
        return environment.myMapArchive.saveReel(reel, audience: audience)
    }

    /// A Folder is a private editing tool; a Bubble attached to a Reel is a
    /// frozen publication snapshot. Copying the selected memories here keeps a
    /// later Folder rename, edit, or deletion from changing an existing Reel.
    private func makeBubbleSnapshot(
        from source: MapTalkReelBubbleSource,
        at coordinate: CLLocationCoordinate2D,
        createdAt: Date,
        audience: MapPublishAudience
    ) -> JourneyPost? {
        let archive = environment.myMapArchive
        let references: [JourneyFolder.MemberReference]
        let title: String

        switch source {
        case let .memories(selectedReferences):
            references = unique(selectedReferences)
            title = "Bubble"

        case let .folder(folderID):
            guard let folder = archive.journeyFolders.first(where: {
                $0.id == folderID && $0.userId == archive.currentUserID
            }) else {
                return nil
            }
            references = unique(folder.memberReferences)
            title = folder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Bubble"
                : folder.title

        }

        var reels: [RealPost] = []
        var places: [RatedPOI] = []
        for reference in references {
            switch reference {
            case let .reel(id):
                guard var reel = archive.privateReels.first(where: {
                    $0.id == id && $0.userId == archive.currentUserID
                }) else { continue }
                // V1 Bubbles do not recursively publish another attached
                // Bubble. The selected Reel itself remains intact in MyMap.
                reel.capsuleId = nil
                reel.likes = []
                reel.comments = []
                reel.visibility = audience == .livePublic ? .publicAll : .privateOnly
                reels.append(reel)

            case let .poi(id):
                guard let place = archive.privatePOIs.first(where: { $0.id == id }),
                      let personalPlace = personalBubbleProjection(of: place) else {
                    continue
                }
                places.append(personalPlace)
            }
        }

        guard reels.isEmpty == false || places.isEmpty == false else { return nil }
        return JourneyPost(
            id: UUID(),
            userId: archive.currentUserID,
            title: title,
            content: "",
            coordinate: coordinate,
            createdAt: createdAt,
            orderedMemberReferences: references,
            reels: reels,
            pois: places,
            likes: [],
            comments: []
        )
    }

    private func personalBubbleProjection(of rated: RatedPOI) -> RatedPOI? {
        let personalVisits = rated.checkIns.filter {
            $0.userId == environment.myMapArchive.currentUserID
        }
        guard personalVisits.isEmpty == false else { return nil }

        var result = rated
        result.media = []
        result.checkIns = personalVisits
        result.comments = []
        result.endorsements = .init(hype: 0, solid: 0, meh: 0, questionable: 0)
        result.tags = personalTagStats(from: personalVisits)
        result.favoritesCount = 0
        return result
    }

    private func personalTagStats(
        from visits: [RatedPOI.CheckIn]
    ) -> [RatedPOI.TagStat] {
        let counts = visits.reduce(into: [VisitTag: Int]()) { result, visit in
            guard let tag = visit.tag else { return }
            result[tag, default: 0] += 1
        }
        return counts
            .sorted { $0.value > $1.value }
            .map { .init(tag: $0.key, count: $0.value) }
    }

    private func unique(
        _ references: [JourneyFolder.MemberReference]
    ) -> [JourneyFolder.MemberReference] {
        references.reduce(into: []) { result, reference in
            if result.contains(reference) == false {
                result.append(reference)
            }
        }
    }

    private func bind() {
        environment.location.authorization
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.locationAuthorization = status
                if status == .denied || status == .restricted {
                    self?.shouldCenterWhenLocationArrives = false
                }
            }
            .store(in: &cancellables)

        // `location` is a CurrentValueSubject. Keep direct subscriptions so
        // every branch receives its current value; `share()` would not replay
        // that value to subscribers attached after the first sink connects.
        let locationStream = environment.location.location

        locationStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                guard let self else { return }
                liveLocation = location
                userCoordinate = MapStartupLocation.usable(location)?.coordinate
                if shouldApplyInitialLocation, let location = MapStartupLocation.usable(location) {
                    shouldApplyInitialLocation = false
                    region = MapStartupLocation.region(around: location.coordinate)
                } else if shouldCenterWhenLocationArrives, let location = MapStartupLocation.usable(location) {
                    shouldCenterWhenLocationArrives = false
                    centerRegion(on: location.coordinate)
                }
            }
            .store(in: &cancellables)

        locationStream
            .compactMap { $0?.coordinate }
            .removeDuplicates { previous, next in
                previous.distance(to: next) < 25
            }
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .map { [environment] coordinate in
                environment.poiRepo.near(coordinate)
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pois in
                self?.nearbySocialPOIs = pois
            }
            .store(in: &cancellables)

        mapSearchRegion
            .map { [environment] region in
                environment.poiRepo.near(region.center)
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pois in
                guard let self else { return }
                repositoryPOIs = pois
                rebuildMapRenderContent()
            }
            .store(in: &cancellables)

        mapSearchRegion
            .map { [environment] region in
                environment.realRepo.active(in: Self.mapRect(for: region))
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reals in
                guard let self else { return }
                repositoryMapReels = reals
                rebuildMapRenderContent()
            }
            .store(in: &cancellables)

        locationStream
            .compactMap { $0?.coordinate }
            .removeDuplicates { previous, next in
                previous.distance(to: next) < 10
            }
            .merge(with: nearbyPlaceRefresh)
            .handleEvents(receiveOutput: { [weak self] _ in
                self?.isLoadingNearbyPlaces = true
            })
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .map { [environment] coordinate in
                environment.nearbyPOIRepo.near(coordinate)
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] places in
                self?.nearbyDirectoryPOIs = places
                self?.isLoadingNearbyPlaces = false
            }
            .store(in: &cancellables)

        environment.myMapArchive.$publicPOIOverlays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] overlays in
                guard let self else { return }
                publishedPOIOverlays = overlays
                rebuildMapRenderContent()
                rebuildActiveFeed(asOf: .now)
            }
            .store(in: &cancellables)

        environment.myMapArchive.$publicReelOverlays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] overlays in
                guard let self else { return }
                publishedReelOverlays = overlays
                rebuildMapRenderContent()
                rebuildActiveFeed(asOf: .now)
            }
            .store(in: &cancellables)

        environment.activePOIRepo
            .active(in: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] places in
                guard let self else { return }
                repositoryActivePOIs = places
                rebuildActiveFeed(asOf: .now)
            }
            .store(in: &cancellables)

        environment.realRepo
            .active(in: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reals in
                guard let self else { return }
                self.repositoryActiveReels = reals
                self.rebuildActiveFeed(asOf: .now)
            }
            .store(in: &cancellables)

        searchMap(in: region)
    }

    private func loadUserScope(for user: User, updateRegion: Bool = true) {
        if let backend = environment.backend {
            let revision = backend.publicContentRevision
            Task { [weak self] in
                do {
                    var receivedFirstSnapshot = false
                    let apply: (BackendStore.Snapshot) -> Void = { [weak self] content in
                        guard let self, !Task.isCancelled, backend.isActive,
                              revision == backend.publicContentRevision else { return }
                        repositoryPOIs = content.pois
                        repositoryMapReels = content.reels
                        repositoryActiveReels = content.reels
                        rebuildMapRenderContent()
                        activeFeedPOIs = content.pois
                        activeFeedReels = content.reels
                        activityPOIs = content.pois
                        activityReels = content.reels
                        activeFeedItems = MapStoryFeed.items(reals: content.reels, ratedPOIs: content.pois,
                            onlyRecentPOIStories: false, userProvider: self.user(for:), now: .now)
                        if updateRegion, !receivedFirstSnapshot, let contentRegion = UserMapViewModel.region(forCoordinates:
                            content.pois.map { $0.poi.coordinate } + content.reels.map(\.center)) {
                            region = contentRegion
                        }
                        // Media arriving later must not pull the camera away
                        // after the person has already started exploring.
                        receivedFirstSnapshot = true
                    }
                    let content = try await backend.loadProfile(userID: user.id, onUpdate: apply)
                    apply(content)
                } catch {
                    if backend.isActive, !(error is CancellationError) { backend.issue = error.localizedDescription }
                }
            }
            return
        }
        let snapshot = UserMapViewModel(
            environment: environment,
            context: .profileContext(for: user)
        )
        repositoryPOIs = snapshot.footprints.map(\.ratedPOI)
        repositoryMapReels = snapshot.reels
        repositoryActiveReels = snapshot.reels
        rebuildMapRenderContent()
        activeFeedPOIs = repositoryPOIs
        activeFeedReels = repositoryActiveReels
        activityPOIs = repositoryPOIs
        activityReels = repositoryActiveReels
        activeFeedItems = MapStoryFeed.items(
            reals: repositoryActiveReels,
            ratedPOIs: repositoryPOIs,
            onlyRecentPOIStories: false,
            userProvider: user(for:),
            now: .now
        )
        userCoordinate = nil
        liveLocation = nil
        region = snapshot.mapRegion
    }

    private func rebuildMapRenderContent(asOf now: Date = .now) {
        freshnessDate = now
        let places = mergePOIs(
            preferred: publishedPOIOverlays,
            fallback: repositoryPOIs
        )
        // receive(on:) may still deliver a pre-withdrawal publisher snapshot.
        // Never let that queued snapshot put a withdrawn record back on screen.
        ratedPOIs = places.compactMap { removingUnavailableMapVisits(from: $0) }
        reals = merge(publishedReelOverlays, with: repositoryMapReels)
            .filter { !unavailableMapMemoryIDs.contains($0.id) }
            .filter { isUserScope || StoryReadKeys.isActive($0, asOf: now) }

        guard case .global = scope else { return }
        // A place is either active or quiet, never both. Keep full public visit
        // history in the card; only its presentation changes when it ages out.
        let historySources = mergePOIs(preferred: ratedPOIs, fallback: repositoryActivePOIs)
        let publicHistory = BackendStore.removingMemories(unavailableMapMemoryIDs, from: historySources)
        let retainedIDs = Set(activeFeedPOIs.filter { hasRecentVisit($0, asOf: now) }.map(\.id))
        let canonicalFootprints = publicHistory.compactMap { place -> MapTalkFriendFootprint? in
            guard !retainedIDs.contains(place.id) else { return nil }
            return MapTalkFriendFootprint.history(for: place, asOf: now)
        }
        let sourceIDs = Set(publicHistory.map(\.id))
        friendFootprints = canonicalFootprints + previewFootprints.filter {
            !sourceIDs.contains($0.ratedPOI.id) && !retainedIDs.contains($0.ratedPOI.id)
        }
        scheduleNextActiveFeedExpiry(from: activeFeedItems, asOf: now)
    }

    /// Builds one feed snapshot for a deliberate source/lifecycle event.
    /// SwiftUI body recomputation (including a tap) only reads this snapshot,
    /// so wall-clock filtering can no longer make an item disappear mid-tap.
    private func rebuildActiveFeed(asOf now: Date) {
        guard case .global = scope else { return }

        activeFeedExpiryWorkItem?.cancel()

        let mergedPlaces = mergePOIs(
            preferred: publishedPOIOverlays,
            fallback: repositoryActivePOIs
        )
        let feedPOIs = withdrawnPublicMemoryIDs.isEmpty ? mergedPlaces : BackendStore.removingMemories(withdrawnPublicMemoryIDs, from: mergedPlaces)
        let allFeedReels = merge(publishedReelOverlays, with: repositoryActiveReels)
            .filter { !withdrawnPublicMemoryIDs.contains($0.id) }
        activityPOIs = feedPOIs
        activityReels = allFeedReels
        let feedReels = allFeedReels
            .filter { StoryReadKeys.isActive($0, asOf: now) }
        var items = MapStoryFeed.items(
            reals: feedReels,
            ratedPOIs: feedPOIs,
            onlyRecentPOIStories: true,
            userProvider: user(for:),
            now: now
        )
        if let retainedActiveFeedItemID,
           items.contains(where: { $0.id == retainedActiveFeedItemID }) == false,
           let retained = activeFeedItems.first(where: { $0.id == retainedActiveFeedItemID }) {
            items.append(retained)
            items.sort { $0.timestamp > $1.timestamp }
        }

        activeFeedItems = items
        activeFeedReels = items.compactMap { item in
            guard case let .real(real) = item.source else { return nil }
            return real
        }
        activeFeedPOIs = items.compactMap { item in
            guard case let .poi(group) = item.source else { return nil }
            return group.ratedPOI
        }

        rebuildMapRenderContent(asOf: now)
    }

    private func scheduleNextActiveFeedExpiry(
        from items: [RealStoriesRow.StoryItem],
        asOf now: Date
    ) {
        activeFeedExpiryWorkItem?.cancel()
        // Map-only content also needs to age out without another camera move
        // or network request. Include every visit, not just each person's latest.
        let mapExpiryDates = (repositoryMapReels + publishedReelOverlays).map { StoryReadKeys.expiresAt(for: $0) }
            + ratedPOIs.flatMap { $0.checkIns.map { StoryReadKeys.expiresAt(forActivityAt: $0.activityDate) } }
        let expiryDates = (items.flatMap { item -> [Date] in
            switch item.source {
            case let .real(real):
                return [StoryReadKeys.expiresAt(for: real)]
            case let .poi(group):
                return group.sharers.map {
                    StoryReadKeys.expiresAt(forActivityAt: $0.timestamp)
                }
            case .journey:
                return []
            }
        } + mapExpiryDates)
        .filter { $0 > now }

        guard let nextExpiry = expiryDates.min() else { return }
        let delay = max(0.05, nextExpiry.timeIntervalSince(now) + 0.01)
        let workItem = DispatchWorkItem { [weak self] in
            self?.rebuildActiveFeed(asOf: .now)
        }
        activeFeedExpiryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    /// POI selection is intentionally proximity-based, not map-visible based.
    /// Map browsing might be on another continent; the nearby radius is always
    /// measured against the device reading used to publish. The returned
    /// choices retain where each landmark came from so the picker can add
    /// useful social context without duplicating one POI into several lists.
    func nearbyPlaceOptions(
        near location: CLLocation,
        withinMeters radius: CLLocationDistance? = nil,
        matching additionalDirectoryPlaces: [RatedPOI] = []
    ) -> [MapTalkNearbyPlaceOption] {
        // A named search adds candidates to the same provenance-aware path;
        // it never bypasses distance checks or promotes private history.
        let directoryPlaces = (additionalDirectoryPlaces + nearbyDirectoryPOIs).map { place -> RatedPOI in
            guard let canonical = environment.backend?.canonicalPlaceForSelection(place.poi, fromDirectory: true) else { return place }
            return RatedPOI(
                poi: canonical,
                highlight: place.highlight, secondary: place.secondary, media: place.media,
                checkIns: place.checkIns, comments: place.comments, endorsements: place.endorsements,
                tags: place.tags, isFavoritedByCurrentUser: place.isFavoritedByCurrentUser,
                favoritesCount: place.favoritesCount
            )
        }
        let directoryIDs = Set(directoryPlaces.map(\.id))
        let archivedIDs = Set(environment.myMapArchive.privatePOIs.map(\.id))
        let friends = environment.backend == nil ? PreviewData.sampleFriends : []
        let friendDirectory = friends.reduce(into: [UUID: User]()) {
            $0[$1.id] = $1
        }

        // Keep public social history separate from MyMap so a private check-in
        // can never be presented as friend activity.
        var publicSocialCandidates: [UUID: RatedPOI] = [:]
        for place in nearbySocialPOIs + repositoryActivePOIs {
            if let existing = publicSocialCandidates[place.id] {
                publicSocialCandidates[place.id] = mergedPOI(
                    publicVersion: existing,
                    archivedVersion: place
                )
            } else {
                publicSocialCandidates[place.id] = place
            }
        }
        for overlay in publishedPOIOverlays {
            if let existing = publicSocialCandidates[overlay.id] {
                publicSocialCandidates[overlay.id] = mergedPOI(
                    publicVersion: overlay,
                    archivedVersion: existing
                )
            } else {
                publicSocialCandidates[overlay.id] = overlay
            }
        }

        // Apple directory results and social POIs share one canonical list.
        // A reducer is intentional here: Dictionary(uniqueKeysWithValues:)
        // would crash if any provider ever returned a duplicate canonical ID.
        var publicCandidates: [UUID: RatedPOI] = [:]
        for place in directoryPlaces {
            if let existing = publicCandidates[place.id] {
                publicCandidates[place.id] = mergedPOI(
                    publicVersion: existing,
                    archivedVersion: place
                )
            } else {
                publicCandidates[place.id] = place
            }
        }
        for socialPlace in publicSocialCandidates.values {
            if let existing = publicCandidates[socialPlace.id] {
                publicCandidates[socialPlace.id] = mergedPOI(
                    publicVersion: socialPlace,
                    archivedVersion: existing
                )
            } else {
                publicCandidates[socialPlace.id] = socialPlace
            }
        }

        var candidates = publicCandidates

        for archived in environment.myMapArchive.privatePOIs {
            if let publicVersion = candidates[archived.id] {
                candidates[archived.id] = mergedPOI(
                    publicVersion: publicVersion,
                    archivedVersion: archived
                )
            } else {
                candidates[archived.id] = archived
            }
        }

        let sorted = candidates.values
            .map { place -> RatedPOI in
                guard let canonical = environment.backend?.canonicalPlaceForSelection(place.poi) else { return place }
                return RatedPOI(poi: canonical,
                    highlight: place.highlight, secondary: place.secondary, media: place.media,
                    checkIns: place.checkIns, comments: place.comments, endorsements: place.endorsements,
                    tags: place.tags, isFavoritedByCurrentUser: place.isFavoritedByCurrentUser,
                    favoritesCount: place.favoritesCount)
            }
            .compactMap { rated -> MapTalkNearbyPlaceOption? in
                let candidate = CLLocation(
                    latitude: rated.poi.coordinate.latitude,
                    longitude: rated.poi.coordinate.longitude
                )
                let distance = candidate.distance(from: location)
                let allowedRadius = radius ?? POISelectionPolicy.radius(for: rated.poi.directoryKind)
                guard distance <= allowedRadius else { return nil }

                // Social proof is derived only from publicly visible source
                // data. Never infer it from the merged private MyMap copy.
                let publicCheckIns = publicSocialCandidates[rated.id]?.checkIns ?? []
                let publicVisitorCount = Set(publicCheckIns.map(\.userId)).count
                var seenFriendIDs = Set<UUID>()
                let friends = publicCheckIns
                    .sorted { $0.createdAt > $1.createdAt }
                    .compactMap { checkIn -> User? in
                        guard let friend = friendDirectory[checkIn.userId],
                              seenFriendIDs.insert(friend.id).inserted else {
                            return nil
                        }
                        return friend
                    }

                return MapTalkNearbyPlaceOption(
                    place: rated,
                    distanceMeters: distance,
                    isPublicDirectoryPlace: directoryIDs.contains(rated.id),
                    isInMyMap: archivedIDs.contains(rated.id),
                    friendUsers: friends,
                    publicVisitorCount: publicVisitorCount
                )
            }
            .sorted { lhs, rhs in
                if abs(lhs.distanceMeters - rhs.distanceMeters) > 0.5 {
                    return lhs.distanceMeters < rhs.distanceMeters
                }
                if lhs.isInMyMap != rhs.isInMyMap {
                    return lhs.isInMyMap
                }
                if lhs.friendUsers.isEmpty != rhs.friendUsers.isEmpty {
                    return lhs.friendUsers.isEmpty == false
                }
                return lhs.place.poi.name.localizedCaseInsensitiveCompare(rhs.place.poi.name) == .orderedAscending
            }

        // The directory already bounds its work. A six-row shortlist used to
        // hide valid neighboring venues (especially the seventh or eighth)
        // and discard places 120–150 m away even though publication allows
        // them. Let the list scroll instead of silently removing choices.
        return sorted
    }

    /// The world map carries other people's history; MyMap carries the
    /// current person's history. When the same POI exists in both sources,
    /// retain the public landmark's metadata while unioning check-ins by ID so
    /// a second private attachment never overwrites the first one.
    private func mergedPOI(
        publicVersion: RatedPOI,
        archivedVersion: RatedPOI
    ) -> RatedPOI {
        var merged = publicVersion
        let publicCheckInIDs = Set(publicVersion.checkIns.map(\.id))
        let archiveOnlyCheckIns = archivedVersion.checkIns.filter {
            publicCheckInIDs.contains($0.id) == false
        }
        merged.checkIns = archiveOnlyCheckIns + publicVersion.checkIns

        let publicMediaIDs = Set(publicVersion.media.map(\.id))
        merged.media = archivedVersion.media.filter { publicMediaIDs.contains($0.id) == false } + publicVersion.media
        return merged
    }

    /// Returns only data that is already public. `nearbyPlaceOptions`
    /// deliberately merges MyMap history for the picker, so its `place`
    /// cannot be reused as the base of a public projection.
    private func publicPOI(withID id: UUID) -> RatedPOI? {
        let sources = [
            nearbyDirectoryPOIs.first { $0.id == id },
            nearbySocialPOIs.first { $0.id == id },
            repositoryPOIs.first { $0.id == id },
            repositoryActivePOIs.first { $0.id == id },
            environment.myMapArchive.publicPOIOverlays.first { $0.id == id }
        ].compactMap { $0 }

        guard var result = sources.first else { return nil }
        for source in sources.dropFirst() {
            result = mergedPOI(
                publicVersion: source,
                archivedVersion: result
            )
        }
        return result
    }

    private func emptyPublicPOI(for poi: POI) -> RatedPOI {
        RatedPOI(
            poi: poi,
            highlight: nil,
            secondary: "Added by you",
            media: [],
            checkIns: [],
            comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0),
            tags: [],
            isFavoritedByCurrentUser: false,
            favoritesCount: 0
        )
    }

    private func appending(
        _ checkIn: RatedPOI.CheckIn,
        to place: RatedPOI
    ) -> RatedPOI {
        var updated = place
        updated.checkIns.insert(checkIn, at: 0)

        switch checkIn.endorsement {
        case .hype:
            updated.endorsements.hype += 1
        case .solid:
            updated.endorsements.solid += 1
        case .meh:
            updated.endorsements.meh += 1
        case .questionable:
            updated.endorsements.questionable += 1
        case nil:
            break
        }

        if let tag = checkIn.tag {
            if let tagIndex = updated.tags.firstIndex(where: { $0.tag == tag }) {
                updated.tags[tagIndex].count += 1
            } else {
                updated.tags.append(.init(tag: tag, count: 1))
            }
        }
        return updated
    }

    private func merge<Item: Identifiable>(_ local: [Item], with repository: [Item]) -> [Item]
    where Item.ID: Hashable {
        let localIDs = Set(local.map(\.id))
        return local + repository.filter { localIDs.contains($0.id) == false }
    }

    /// The same canonical place can arrive from the active server stream and
    /// an optimistic local publish. Keep one place while unioning check-ins;
    /// whole-object replacement would drop another person's active visit.
    private func mergePOIs(
        preferred: [RatedPOI],
        fallback: [RatedPOI]
    ) -> [RatedPOI] {
        var result = fallback
        for place in preferred.reversed() {
            if let index = result.firstIndex(where: { $0.id == place.id }) {
                result[index] = mergedPOI(
                    publicVersion: place,
                    archivedVersion: result[index]
                )
            } else {
                result.insert(place, at: 0)
            }
        }
        return result
    }

    private static func mapRect(for region: MKCoordinateRegion) -> MKMapRect {
        if region.span.latitudeDelta >= 180 || region.span.longitudeDelta >= 360 {
            return .world
        }

        let halfLatitude = region.span.latitudeDelta / 2
        let halfLongitude = region.span.longitudeDelta / 2
        let west = region.center.longitude - halfLongitude
        let east = region.center.longitude + halfLongitude
        if west < -180 || east > 180 {
            return .world
        }
        let mercatorLatitudeLimit = 85.051_128_78
        let northWest = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: min(mercatorLatitudeLimit, region.center.latitude + halfLatitude),
                longitude: west
            )
        )
        let southEast = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: max(-mercatorLatitudeLimit, region.center.latitude - halfLatitude),
                longitude: east
            )
        )
        return MKMapRect(
            x: min(northWest.x, southEast.x),
            y: min(northWest.y, southEast.y),
            width: abs(southEast.x - northWest.x),
            height: abs(southEast.y - northWest.y)
        )
    }

    private func regionAround(
        coordinate: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance,
        minimumRadius: CLLocationDistance = 200
    ) -> MKCoordinateRegion {
        let clampedRadius = max(radiusMeters, minimumRadius)
        return MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: clampedRadius * 2,
            longitudinalMeters: clampedRadius * 2
        )
    }
}
