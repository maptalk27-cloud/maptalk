import CoreLocation
import Foundation

/// Describes a media slot even while its bytes are not available locally.
struct FriendStoryMediaDescriptor: Identifiable, Hashable {
    enum Kind: Hashable { case photo, video, emoji }
    let id: UUID
    let kind: Kind
}

/// One original Reel card or one exact POI visit slice. Identity never depends on
/// a download completing, a caption edit, or the viewer's current map viewport.
struct FriendStoryPage: Identifiable {
    enum Kind { case reelCard, poiMedia, poiLocationOnly }
    enum Content {
        case reel(RealPost)
        case poi(RatedPOI, RatedPOI.CheckIn, RatedPOI.Media?)
    }

    let id: String
    let authorID: UUID
    let memoryID: UUID
    let mediaID: UUID?
    let publishedAt: Date
    let capturedAt: Date
    let expiresAt: Date
    let readKey: String
    let kind: Kind
    let expectedMedia: [FriendStoryMediaDescriptor]
    let content: Content

    /// Availability is not proof of viewing. The UI marks read only after the
    /// current image/video is actually presented, never when this turns true.
    var isMediaReady: Bool {
        switch content {
        case let .reel(real):
            let availableIDs = Set(real.attachments.map(\.id))
            return expectedMedia.allSatisfy { availableIDs.contains($0.id) }
        case let .poi(_, _, media):
            return kind == .poiLocationOnly || media != nil
        }
    }

    var coordinate: CLLocationCoordinate2D? {
        let value: CLLocationCoordinate2D
        switch content {
        case let .reel(real): value = real.center
        case let .poi(rated, _, _): value = rated.poi.coordinate
        }
        return CLLocationCoordinate2DIsValid(value) ? value : nil
    }

    /// Shared-place identity prevents camera movement for different visits or
    /// different people at the same place. This is not a live user location.
    var locationKey: String? {
        guard coordinate != nil else { return nil }
        switch content {
        case .reel: return "reel:\(memoryID.uuidString)"
        case let .poi(rated, _, _): return "place:\(rated.id.uuidString)"
        }
    }

    var discussionTarget: BackendCommentTarget {
        switch content {
        case .reel: return .memory(memoryID)
        case let .poi(rated, _, _): return .place(rated.id)
        }
    }
}

/// One continuous stop in a person's story. Pages stay individually addressable
/// for swiping, read state and deletion; only their navigation chrome is grouped.
struct FriendStoryMoment: Identifiable {
    let id: String
    let pageRange: Range<Int>
    let placeID: UUID?
}

struct FriendStoryGroup: Identifiable {
    let authorID: UUID
    var user: User?
    let pages: [FriendStoryPage]
    let moments: [FriendStoryMoment]
    private let viewedKeys: Set<String>

    var id: UUID { authorID }
    var latestTimestamp: Date { pages.map(\.publishedAt).max() ?? .distantPast }
    var readKeys: [String] { pages.map(\.readKey) }
    var hasUnviewed: Bool { pages.contains { !viewedKeys.contains($0.readKey) } }

    init(authorID: UUID, user: User?, pages: [FriendStoryPage], viewedKeys: Set<String> = []) {
        self.authorID = authorID
        self.user = user
        self.pages = pages
        self.moments = Self.makeMoments(pages)
        self.viewedKeys = viewedKeys
    }

    func momentIndex(containing pageIndex: Int) -> Int? {
        moments.firstIndex { $0.pageRange.contains(pageIndex) }
    }

    private static func makeMoments(_ pages: [FriendStoryPage]) -> [FriendStoryMoment] {
        var moments: [FriendStoryMoment] = []
        for (index, page) in pages.enumerated() {
            let placeID: UUID?
            if case let .poi(place, _, _) = page.content { placeID = place.id }
            else { placeID = nil }
            if let placeID, let previous = moments.last, previous.placeID == placeID,
               pages[previous.pageRange.lowerBound].authorID == page.authorID {
                moments[moments.count - 1] = .init(id: previous.id,
                    pageRange: previous.pageRange.lowerBound..<(index + 1), placeID: placeID)
            } else {
                moments.append(.init(id: page.id, pageRange: index..<(index + 1), placeID: placeID))
            }
        }
        return moments
    }

    fileprivate func replacingPages(_ pages: [FriendStoryPage]) -> Self {
        .init(authorID: authorID, user: user, pages: pages, viewedKeys: viewedKeys)
    }
}

/// Feed metadata, not map search results, is the source of membership. With a
/// backend snapshot supplied, UI projections only supply already-cached media.
@MainActor
enum FriendStoryFeed {
    static func groups(
        reals: [RealPost],
        ratedPOIs: [RatedPOI],
        backendRecords: [BackendMemory]? = nil,
        viewedKeys: Set<String> = [],
        userProvider: (UUID) -> User?,
        now: Date = .now
    ) -> [FriendStoryGroup] {
        let pages: [FriendStoryPage]
        var backendUsers: [UUID: User] = [:]
        if let backendRecords {
            pages = backendPages(records: backendRecords, reals: reals, ratedPOIs: ratedPOIs, now: now)
            for record in backendRecords where backendUsers[record.ownerId] == nil {
                // The authenticated owner ID, not an optional profile payload,
                // determines authorship.
                backendUsers[record.ownerId] = User(id: record.ownerId,
                    handle: record.owner.handle, avatarURL: nil)
            }
        } else {
            pages = projectedPages(reals: reals, ratedPOIs: ratedPOIs, now: now)
        }
        return Dictionary(grouping: pages, by: \.authorID).map { authorID, pages in
            FriendStoryGroup(authorID: authorID, user: userProvider(authorID) ?? backendUsers[authorID],
                pages: pages.sorted(by: pageOrder), viewedKeys: viewedKeys)
        }.sorted {
            if $0.hasUnviewed != $1.hasUnviewed { return $0.hasUnviewed }
            if $0.latestTimestamp != $1.latestTimestamp { return $0.latestTimestamp > $1.latestTimestamp }
            return $0.authorID.uuidString < $1.authorID.uuidString
        }
    }

    private static func pageOrder(_ lhs: FriendStoryPage, _ rhs: FriendStoryPage) -> Bool {
        if lhs.publishedAt != rhs.publishedAt { return lhs.publishedAt < rhs.publishedAt }
        if lhs.memoryID != rhs.memoryID { return lhs.memoryID.uuidString < rhs.memoryID.uuidString }
        // Pages are emitted in source media order. Swift's stable sort preserves
        // that order for slices of the same original publication.
        return false
    }

    private static func projectedPages(reals: [RealPost], ratedPOIs: [RatedPOI], now: Date) -> [FriendStoryPage] {
        var pages: [FriendStoryPage] = []
        var seenRecords = Set<UUID>()
        for real in reals where real.visibility != .privateOnly && StoryReadKeys.isActive(real, asOf: now) {
            guard seenRecords.insert(real.id).inserted else { continue }
            pages.append(reelPage(real, descriptors: real.attachments.map(descriptor),
                expiresAt: StoryReadKeys.expiresAt(for: real)))
        }
        for rated in ratedPOIs {
            for checkIn in rated.checkIns where StoryReadKeys.isFresh(checkIn.activityDate, asOf: now) {
                guard seenRecords.insert(checkIn.id).inserted else { continue }
                pages += poiPages(rated, checkIn: checkIn, descriptors: checkIn.media.map(descriptor),
                    expiresAt: StoryReadKeys.expiresAt(forActivityAt: checkIn.activityDate))
            }
        }
        return pages
    }

    private static func backendPages(
        records: [BackendMemory], reals: [RealPost], ratedPOIs: [RatedPOI], now: Date
    ) -> [FriendStoryPage] {
        let realLookup = Dictionary(reals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placeLookup = Dictionary(ratedPOIs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visitLookup = Dictionary(ratedPOIs.flatMap { place in
            place.checkIns.map { ($0.id, (placeID: place.id, visit: $0)) }
        }, uniquingKeysWith: { first, _ in first })
        var seenRecords = Set<UUID>()
        var pages: [FriendStoryPage] = []
        for record in records {
            let publication = record.publishedAt ?? record.createdAt
            guard record.visibility == "public",
                  record.moderationStatus == nil || record.moderationStatus == "approved",
                  StoryReadKeys.isFresh(publication, asOf: now),
                  seenRecords.insert(record.id).inserted else { continue }
            let expiresAt = StoryReadKeys.expiresAt(forActivityAt: publication)
            var mediaIDs = Set<UUID>()
            let descriptors = record.media.compactMap { media -> FriendStoryMediaDescriptor? in
                guard mediaIDs.insert(media.id).inserted else { return nil }
                return .init(id: media.id, kind: media.mimeType.hasPrefix("video/") ? .video : .photo)
            }
            switch record.kind {
            case "reel":
                let projected = realLookup[record.id].flatMap { $0.userId == record.ownerId ? $0 : nil }
                let cached = Dictionary((projected?.attachments ?? []).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first })
                let real = RealPost(id: record.id, userId: record.ownerId,
                    center: .init(latitude: record.location.latitude, longitude: record.location.longitude),
                    radiusMeters: projected?.radiusMeters ?? 220,
                    message: record.caption.isEmpty ? nil : record.caption,
                    attachments: descriptors.compactMap { cached[$0.id] }, capsuleId: projected?.capsuleId,
                    likes: projected?.likes ?? [], comments: projected?.comments ?? [], visibility: .publicAll,
                    createdAt: record.createdAt, expiresAt: expiresAt, publishedAt: record.publishedAt)
                pages.append(reelPage(real, descriptors: descriptors, expiresAt: expiresAt))
            case "poi":
                guard let place = record.place else { continue }
                var rated = placeLookup[place.id] ?? emptyPlace(place)
                // Refresh canonical place metadata even if cached map content is
                // older. Other contributors stay available only in place scope.
                rated = replacingPlaceMetadata(rated, with: place)
                let projectedVisit = visitLookup[record.id]
                let existing = projectedVisit.flatMap {
                    $0.placeID == place.id && $0.visit.userId == record.ownerId ? $0.visit : nil
                }
                let cached = Dictionary((existing?.media ?? []).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first })
                let visit = RatedPOI.CheckIn(id: record.id, userId: record.ownerId,
                    createdAt: record.createdAt, endorsement: existing?.endorsement,
                    media: descriptors.compactMap { cached[$0.id] }, tag: existing?.tag,
                    publishedAt: record.publishedAt)
                // Usually the shared projection is already current. Avoid a
                // copy-on-write of the entire place's visits for every page.
                if existing != visit {
                    if let index = rated.checkIns.firstIndex(where: { $0.id == visit.id }) {
                        rated.checkIns[index] = visit
                    } else {
                        rated.checkIns.append(visit)
                    }
                }
                pages += poiPages(rated, checkIn: visit, descriptors: descriptors, expiresAt: expiresAt)
            default: continue
            }
        }
        return pages
    }

    private static func emptyPlace(_ place: BackendPlace) -> RatedPOI {
        .init(poi: .init(id: place.id, name: place.name,
            coordinate: .init(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
            category: POICategory(rawValue: place.category) ?? .other,
            directoryKind: place.directoryKind.flatMap(POIDirectoryKind.init(rawValue:))),
            highlight: nil, secondary: nil, media: [], checkIns: [], comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: false, favoritesCount: 0)
    }

    private static func replacingPlaceMetadata(_ rated: RatedPOI, with place: BackendPlace) -> RatedPOI {
        .init(poi: emptyPlace(place).poi, highlight: rated.highlight, secondary: rated.secondary,
            media: rated.media, checkIns: rated.checkIns, comments: rated.comments,
            endorsements: rated.endorsements, tags: rated.tags,
            isFavoritedByCurrentUser: rated.isFavoritedByCurrentUser, favoritesCount: rated.favoritesCount)
    }

    private static func reelPage(
        _ real: RealPost, descriptors: [FriendStoryMediaDescriptor], expiresAt: Date
    ) -> FriendStoryPage {
        .init(id: "reel:\(real.id.uuidString)", authorID: real.userId, memoryID: real.id, mediaID: nil,
            publishedAt: real.activityDate, capturedAt: real.createdAt, expiresAt: expiresAt,
            readKey: StoryReadKeys.real(real), kind: .reelCard, expectedMedia: descriptors, content: .reel(real))
    }

    private static func poiPages(
        _ rated: RatedPOI, checkIn: RatedPOI.CheckIn,
        descriptors: [FriendStoryMediaDescriptor], expiresAt: Date
    ) -> [FriendStoryPage] {
        if descriptors.isEmpty {
            return [.init(id: "poi:\(checkIn.id.uuidString):visit", authorID: checkIn.userId,
                memoryID: checkIn.id, mediaID: nil, publishedAt: checkIn.activityDate,
                capturedAt: checkIn.createdAt, expiresAt: expiresAt,
                readKey: "poi-visit:\(rated.id.uuidString):\(checkIn.id.uuidString):\(Int(checkIn.activityDate.timeIntervalSinceReferenceDate))",
                kind: .poiLocationOnly, expectedMedia: [], content: .poi(rated, checkIn, nil))]
        }
        let cached = Dictionary(checkIn.media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return descriptors.map { media in
            .init(id: "poi:\(checkIn.id.uuidString):\(media.id.uuidString)", authorID: checkIn.userId,
                memoryID: checkIn.id, mediaID: media.id, publishedAt: checkIn.activityDate,
                capturedAt: checkIn.createdAt, expiresAt: expiresAt,
                readKey: StoryReadKeys.poiStoryPage(poiId: rated.id, checkInId: checkIn.id,
                    mediaId: media.id, timestamp: checkIn.activityDate),
                kind: .poiMedia, expectedMedia: [media], content: .poi(rated, checkIn, cached[media.id]))
        }
    }

    private static func descriptor(_ media: RatedPOI.Media) -> FriendStoryMediaDescriptor {
        switch media.kind {
        case .photo: return .init(id: media.id, kind: .photo)
        case .video: return .init(id: media.id, kind: .video)
        }
    }

    private static func descriptor(_ media: RealPost.Attachment) -> FriendStoryMediaDescriptor {
        switch media.kind {
        case .photo: return .init(id: media.id, kind: .photo)
        case .video: return .init(id: media.id, kind: .video)
        case .emoji: return .init(id: media.id, kind: .emoji)
        }
    }
}

/// A frozen viewing sequence, deliberately independent of sheet, camera and
/// nested-route state. A refresh updates payloads/removes revoked records, but
/// never inserts new pages or reorders authors beneath a gesture.
struct FriendStorySession {
    private(set) var groups: [FriendStoryGroup]
    private(set) var selectedAuthorID: UUID?
    private(set) var resumePageIDs: [UUID: String] = [:]

    var isEnded: Bool { selectedAuthorID == nil }
    var currentGroup: FriendStoryGroup? { groups.first { $0.authorID == selectedAuthorID } }
    var currentPage: FriendStoryPage? {
        guard let group = currentGroup, let id = resumePageIDs[group.authorID] else { return nil }
        return group.pages.first { $0.id == id }
    }
    var currentPageIndex: Int? {
        guard let group = currentGroup, let page = currentPage else { return nil }
        return group.pages.firstIndex { $0.id == page.id }
    }

    init?(groups: [FriendStoryGroup], authorID: UUID, viewedKeys: Set<String> = [],
          resuming pageIDs: [UUID: String] = [:]) {
        var seenAuthors = Set<UUID>()
        self.groups = groups.filter { !$0.pages.isEmpty && seenAuthors.insert($0.authorID).inserted }
        guard let group = self.groups.first(where: { $0.authorID == authorID }) else { return nil }
        // Explicit avatar selection may adopt a newer feed snapshot. Keep
        // cursors only for pages still present in that author's fresh group.
        for group in self.groups {
            if let id = pageIDs[group.authorID], group.pages.contains(where: { $0.id == id }) {
                resumePageIDs[group.authorID] = id
            }
        }
        selectedAuthorID = authorID
        if resumePageIDs[authorID] == nil {
            resumePageIDs[authorID] = Self.initialPage(in: group, viewedKeys: viewedKeys)?.id
        }
    }

    @discardableResult
    mutating func selectAuthor(id: UUID, viewedKeys: Set<String> = []) -> Bool {
        guard !isEnded, let group = groups.first(where: { $0.authorID == id }) else { return false }
        let changed = selectedAuthorID != id
        selectedAuthorID = id
        if !group.pages.contains(where: { $0.id == resumePageIDs[id] }) {
            resumePageIDs[id] = Self.initialPage(in: group, viewedKeys: viewedKeys)?.id
        }
        return changed
    }

    @discardableResult
    mutating func selectPage(id: String) -> Bool {
        guard let group = currentGroup, group.pages.contains(where: { $0.id == id }) else { return false }
        let changed = resumePageIDs[group.authorID] != id
        resumePageIDs[group.authorID] = id
        return changed
    }

    @discardableResult
    mutating func movePage(by offset: Int) -> Bool {
        guard let group = currentGroup, let index = currentPageIndex else { return false }
        let (target, overflow) = index.addingReportingOverflow(offset)
        guard !overflow, group.pages.indices.contains(target) else { return false }
        return selectPage(id: group.pages[target].id)
    }

    @discardableResult
    mutating func moveAuthor(by offset: Int, viewedKeys: Set<String> = []) -> Bool {
        guard let index = groups.firstIndex(where: { $0.authorID == selectedAuthorID }) else { return false }
        let (target, overflow) = index.addingReportingOverflow(offset)
        guard !overflow, groups.indices.contains(target) else { return false }
        return selectAuthor(id: groups[target].authorID, viewedKeys: viewedKeys)
    }

    /// `validMemoryIDs` is an authoritative access/withdrawal set, not a set of
    /// cached media IDs. Retaining a naturally expired current page requires
    /// explicit evidence it is still permitted; absence never implies access.
    mutating func reconcile(
        with refreshedGroups: [FriendStoryGroup],
        now: Date = .now,
        retainCurrentExpiredPage: Bool = false,
        validMemoryIDs: Set<UUID>? = nil
    ) {
        guard !isEnded else { return }
        let oldCurrentGroup = currentGroup
        let oldCurrentPage = currentPage
        let updates = Dictionary(refreshedGroups.map { ($0.authorID, $0) },
            uniquingKeysWith: { first, _ in first })
        groups = groups.compactMap { frozen in
            let refreshed = updates[frozen.authorID]
            let available = Dictionary((refreshed?.pages ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            let retained = frozen.pages.compactMap { old -> FriendStoryPage? in
                if let validMemoryIDs, !validMemoryIDs.contains(old.memoryID) { return nil }
                if let page = available[old.id], page.authorID == frozen.authorID,
                   page.memoryID == old.memoryID, page.expiresAt > now {
                    return page
                }
                if retainCurrentExpiredPage, old.id == oldCurrentPage?.id,
                   old.expiresAt <= now, validMemoryIDs?.contains(old.memoryID) == true {
                    return old
                }
                return nil
            }
            guard !retained.isEmpty else { return nil }
            return (refreshed ?? frozen).replacingPages(retained)
        }
        restoreCursor(afterRemovingFrom: oldCurrentGroup, current: oldCurrentPage)
    }

    mutating func invalidate(memoryIDs: Set<UUID>) {
        guard !memoryIDs.isEmpty, !isEnded else { return }
        let oldGroup = currentGroup
        let oldPage = currentPage
        groups = groups.compactMap { group in
            let pages = group.pages.filter { !memoryIDs.contains($0.memoryID) }
            return pages.isEmpty ? nil : group.replacingPages(pages)
        }
        restoreCursor(afterRemovingFrom: oldGroup, current: oldPage)
    }

    mutating func end() {
        selectedAuthorID = nil
        groups = []
        resumePageIDs = [:]
    }

    private mutating func restoreCursor(afterRemovingFrom oldGroup: FriendStoryGroup?, current oldPage: FriendStoryPage?) {
        guard let current = currentGroup, let oldGroup, let oldPage else {
            end()
            return
        }
        let oldIndex = oldGroup.pages.firstIndex { $0.id == oldPage.id } ?? 0
        let survivingIDs = Set(current.pages.map(\.id))
        if !survivingIDs.contains(oldPage.id) {
            let next = oldGroup.pages.dropFirst(oldIndex + 1).first { survivingIDs.contains($0.id) }
            let previous = oldGroup.pages.prefix(oldIndex).last { survivingIDs.contains($0.id) }
            resumePageIDs[current.authorID] = (next ?? previous ?? current.pages.first)?.id
        }
        let survivingAuthors = Set(groups.map(\.authorID))
        resumePageIDs = resumePageIDs.filter { survivingAuthors.contains($0.key) }
        for group in groups where group.authorID != selectedAuthorID {
            if let saved = resumePageIDs[group.authorID], !group.pages.contains(where: { $0.id == saved }) {
                resumePageIDs.removeValue(forKey: group.authorID)
            }
        }
    }

    private static func initialPage(in group: FriendStoryGroup, viewedKeys: Set<String>) -> FriendStoryPage? {
        // A new visit starts with unseen content, or replays the story from
        // its beginning once everything is read. Exact in-session returns
        // are handled separately by resumePageIDs above.
        group.pages.first(where: { !viewedKeys.contains($0.readKey) }) ?? group.pages.first
    }
}
