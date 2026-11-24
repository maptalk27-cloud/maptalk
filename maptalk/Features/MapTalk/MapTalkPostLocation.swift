import CoreLocation
import Foundation

/// A Post's chosen subject location, not a claim about a live POI check-in.
struct MapTalkPostLocationSelection {
    let coordinate: CLLocationCoordinate2D
    let title: String
    /// A display fallback such as “Previous post location” is not a place name.
    var locationName: String? = nil
    var locationID: UUID? = nil
}

struct MapTalkPostLocationChoice: Identifiable {
    let id: String
    let selection: MapTalkPostLocationSelection
    let distanceMeters: CLLocationDistance
    let category: POICategory?
    /// These are exclusively the current person's posts, including private ones.
    /// This count must be described as personal history, never public activity.
    let previousPosts: [RealPost]
    var placeOption: MapTalkNearbyPlaceOption? = nil
    /// Computed while grouping history, rather than walking every older Post
    /// on each SwiftUI body evaluation when none has a renderable thumbnail.
    var cachedThumbnail: URL? = nil

    var postCount: Int { previousPosts.count }
    var isPOI: Bool { category != nil }
    var ownCheckInCount: Int { placeOption?.ownCheckIns.count ?? 0 }
    var hasHistory: Bool { !previousPosts.isEmpty || placeOption?.hasHistory == true }
    var lastOwnActivityAt: Date? {
        [previousPosts.first?.activityDate, placeOption?.ownCheckIns.map(\.activityDate).max()].compactMap { $0 }.max()
    }
    var historyPriority: Int {
        if !previousPosts.isEmpty || ownCheckInCount > 0 { return 0 }
        return placeOption?.historyPriority ?? 2
    }
    var thumbnailURL: URL? { cachedThumbnail }
}

enum PostLocationPolicy {
    static let radius: CLLocationDistance = 5_000
    static let maximumNameLength = 80

    static func normalizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= maximumNameLength,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    static func location(for selection: MapTalkPostLocationSelection,
                         near origin: CLLocation) -> CLLocation? {
        guard isValid(origin.coordinate), isValid(selection.coordinate) else { return nil }
        let location = CLLocation(latitude: selection.coordinate.latitude,
                                  longitude: selection.coordinate.longitude)
        let distance = location.distance(from: origin)
        guard distance.isFinite, distance <= radius else { return nil }
        return location
    }

    fileprivate static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && CLLocationCoordinate2DIsValid(coordinate)
    }
}

/// A real owned POI visit unlocks a Post creation area; a saved or merely
/// nearby place does not. These landmark centers never move to a Post's pin.
struct PostLocationVisitArea: Identifiable {
    let id: UUID
    let name: String
    let coordinate: CLLocationCoordinate2D
}

struct PostLocationCoverage {
    let revision = UUID()
    let areas: [PostLocationVisitArea]
    private let index: PostLocationSpatialIndex

    init(areas: [PostLocationVisitArea]) {
        self.areas = areas.filter { PostLocationPolicy.isValid($0.coordinate) }
        index = PostLocationSpatialIndex(coordinates: self.areas.map(\.coordinate))
    }

    func contains(_ coordinate: CLLocationCoordinate2D, currentLocation: CLLocation?) -> Bool {
        guard PostLocationPolicy.isValid(coordinate) else { return false }
        if let currentLocation,
           PostLocationPolicy.location(for: .init(coordinate: coordinate, title: ""), near: currentLocation) != nil {
            return true
        }
        return !index.matches(coordinate, within: PostLocationPolicy.radius, firstOnly: true).isEmpty
    }

    /// Useful for a map viewport without rescanning every historical visit on
    /// every pan. CoreLocation defines the final radius, not the spatial index.
    func areas(near coordinate: CLLocationCoordinate2D, within radius: CLLocationDistance) -> [PostLocationVisitArea] {
        index.matches(coordinate, within: radius).map { areas[$0] }
    }
}

/// A balanced unit-sphere index avoids latitude/longitude wrap and polar edge
/// cases. Its conservative chord bound only prunes candidates; an exact
/// CoreLocation distance check makes the 5 km eligibility decision.
private struct PostLocationSpatialIndex {
    private struct Node {
        let area: Int
        let axis: Int
        let left: Int?
        let right: Int?
    }

    private let coordinates: [CLLocationCoordinate2D]
    private let points: [[Double]]
    private var nodes: [Node] = []
    private var root: Int?

    init(coordinates: [CLLocationCoordinate2D]) {
        self.coordinates = coordinates
        points = coordinates.map { Self.point($0) }
        root = build(Array(coordinates.indices), depth: 0)
    }

    private mutating func build(_ indices: [Int], depth: Int) -> Int? {
        guard !indices.isEmpty else { return nil }
        let axis = depth % 3
        let sorted = indices.sorted {
            points[$0][axis] == points[$1][axis] ? $0 < $1 : points[$0][axis] < points[$1][axis]
        }
        let middle = sorted.count / 2
        let left = build(Array(sorted[..<middle]), depth: depth + 1)
        let right = build(Array(sorted[(middle + 1)...]), depth: depth + 1)
        nodes.append(.init(area: sorted[middle], axis: axis, left: left, right: right))
        return nodes.count - 1
    }

    func matches(_ coordinate: CLLocationCoordinate2D, within radius: CLLocationDistance,
                 firstOnly: Bool = false) -> [Int] {
        guard PostLocationPolicy.isValid(coordinate), radius.isFinite, radius >= 0 else { return [] }
        let target = Self.point(coordinate)
        // 6,330 km is below Earth's minimum meridional radius of curvature,
        // so this is deliberately wider than any WGS-84 surface-distance arc.
        let bound = min(2, radius / 6_330_000 + 1e-12)
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var matches: [Int] = []
        func search(_ nodeIndex: Int?) {
            guard let nodeIndex, !firstOnly || matches.isEmpty else { return }
            let node = nodes[nodeIndex]
            let point = points[node.area]
            let squaredChord = zip(point, target).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) }
            if squaredChord <= bound * bound {
                let center = coordinates[node.area]
                let distance = CLLocation(latitude: center.latitude, longitude: center.longitude).distance(from: location)
                if distance.isFinite && distance <= radius { matches.append(node.area) }
            }
            let delta = target[node.axis] - point[node.axis]
            if delta <= bound { search(node.left) }
            if delta >= -bound { search(node.right) }
        }
        search(root)
        return matches.sorted()
    }

    private static func point(_ coordinate: CLLocationCoordinate2D) -> [Double] {
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        return [cos(latitude) * cos(longitude), cos(latitude) * sin(longitude), sin(latitude)]
    }
}

struct MapTalkPostLocationLibrary {
    static let empty = MapTalkPostLocationLibrary(ownPosts: [], visitedPlaces: [],
        currentUserID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)

    let revision = UUID()
    let choices: [MapTalkPostLocationChoice]
    let coverage: PostLocationCoverage
    let regions: [PostLocationRegion]
    private let historicalSelections: Set<SelectionKey>
    private let historicalIdentities: Set<UUID>

    private struct SelectionKey: Hashable {
        let identity: UUID
        let latitude: Double
        let longitude: Double
        let name: String?

        init(identity: UUID, coordinate: CLLocationCoordinate2D, name: String?) {
            self.identity = identity
            latitude = coordinate.latitude
            longitude = coordinate.longitude
            self.name = name
        }
    }

    init(ownPosts: [RealPost], visitedPlaces: [RatedPOI], currentUserID: UUID) {
        self.init(choices: MapTalkPostLocations.ownedChoices(ownPosts, currentUserID: currentUserID),
                  coverage: Self.coverage(visitedPlaces, currentUserID: currentUserID))
    }

    fileprivate init(choices: [MapTalkPostLocationChoice], coverage: PostLocationCoverage) {
        self.choices = choices
        self.coverage = coverage
        regions = MapTalkPostLocationRegions.make(coordinates:
            coverage.areas.map(\.coordinate) + choices.flatMap { $0.previousPosts.map(\.center) })
        historicalSelections = Set(choices.flatMap { choice -> [SelectionKey] in
            guard let identity = choice.selection.locationID else { return [] }
            return choice.previousPosts.map {
                SelectionKey(identity: identity, coordinate: $0.center, name: $0.locationName)
            }
        })
        historicalIdentities = Set(choices.compactMap { $0.selection.locationID })
    }

    func choices(matching query: String) -> [MapTalkPostLocationChoice] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return choices }
        return choices.filter { $0.selection.title.localizedStandardContains(query) }
    }

    func location(for selection: MapTalkPostLocationSelection, currentLocation: CLLocation?) -> CLLocation? {
        guard PostLocationPolicy.isValid(selection.coordinate) else { return nil }
        if let identity = selection.locationID {
            let key = SelectionKey(identity: identity, coordinate: selection.coordinate, name: selection.locationName)
            if historicalSelections.contains(key) {
                return CLLocation(latitude: selection.coordinate.latitude, longitude: selection.coordinate.longitude)
            }
            // Moving or renaming an existing identity is not historical reuse,
            // even if the new pin happens to be in an otherwise allowed area.
            guard !historicalIdentities.contains(identity) else { return nil }
        }
        guard PostLocationPolicy.normalizedName(selection.locationName) != nil,
              coverage.contains(selection.coordinate, currentLocation: currentLocation) else { return nil }
        return CLLocation(latitude: selection.coordinate.latitude, longitude: selection.coordinate.longitude)
    }

    fileprivate static func coverage(_ visitedPlaces: [RatedPOI], currentUserID: UUID) -> PostLocationCoverage {
        var seen = Set<UUID>()
        let areas = visitedPlaces.filter {
            PostLocationPolicy.isValid($0.poi.coordinate) && $0.checkIns.contains { $0.userId == currentUserID }
        }.sorted {
            if $0.id != $1.id { return $0.id.uuidString < $1.id.uuidString }
            if $0.poi.name != $1.poi.name { return $0.poi.name < $1.poi.name }
            return MapTalkPostLocations.coordinatePrecedes($0.poi.coordinate, $1.poi.coordinate)
        }.filter { seen.insert($0.id).inserted }.map {
            PostLocationVisitArea(id: $0.id, name: $0.poi.name, coordinate: $0.poi.coordinate)
        }
        return PostLocationCoverage(areas: areas)
    }
}

/// Updated only from archive/data publications, never GPS or map gestures.
/// Lightweight semantic revisions skip sorting/grouping and coverage indexing
/// for likes, comments, video progress, and other unrelated repository updates.
struct MapTalkPostLocationCache {
    private(set) var library = MapTalkPostLocationLibrary.empty
    private var owner: UUID?
    private var postRevision = Set<PostRevision>()
    private var areaRevision = Set<AreaRevision>()

    private struct PostRevision: Hashable {
        let id: UUID
        let latitude: Double
        let longitude: Double
        let name: String?
        let identity: UUID?
        let createdAt: Date
        let publishedAt: Date?
        let message: String?
        let thumbnail: URL?

        init(_ post: RealPost) {
            id = post.id
            latitude = post.center.latitude
            longitude = post.center.longitude
            name = post.locationName
            identity = post.locationID
            createdAt = post.createdAt
            publishedAt = post.publishedAt
            message = post.message
            thumbnail = MapTalkPostLocations.thumbnail(post)
        }
    }

    private struct AreaRevision: Hashable {
        let id: UUID
        let name: String
        let latitude: Double
        let longitude: Double

        init(_ place: RatedPOI) {
            id = place.id
            name = place.poi.name
            latitude = place.poi.coordinate.latitude
            longitude = place.poi.coordinate.longitude
        }
    }

    @discardableResult
    mutating func update(ownPosts: [RealPost], visitedPlaces: [RatedPOI], currentUserID: UUID) -> Bool {
        let posts = Set(ownPosts.lazy.filter {
            $0.userId == currentUserID && PostLocationPolicy.isValid($0.center)
        }.map { PostRevision($0) })
        let areas = Set(visitedPlaces.lazy.filter {
            PostLocationPolicy.isValid($0.poi.coordinate) && $0.checkIns.contains { $0.userId == currentUserID }
        }.map { AreaRevision($0) })
        let ownerChanged = owner != currentUserID
        let postsChanged = ownerChanged || posts != postRevision
        let areasChanged = ownerChanged || areas != areaRevision
        guard postsChanged || areasChanged else { return false }
        library = MapTalkPostLocationLibrary(
            choices: postsChanged ? MapTalkPostLocations.ownedChoices(ownPosts, currentUserID: currentUserID) : library.choices,
            coverage: areasChanged ? MapTalkPostLocationLibrary.coverage(visitedPlaces, currentUserID: currentUserID) : library.coverage)
        owner = currentUserID
        postRevision = posts
        areaRevision = areas
        return true
    }
}

enum MapTalkPostLocations {
    /// A sub-metre identity key prevents float serialization from duplicating
    /// the same location. The published coordinate is never rounded or snapped.
    private struct CoordinateKey: Hashable {
        let latitude: Int64
        let longitude: Int64

        init(_ coordinate: CLLocationCoordinate2D) {
            latitude = Int64((coordinate.latitude * 1_000_000).rounded())
            longitude = Int64((coordinate.longitude * 1_000_000).rounded())
        }

        var identifier: String { "\(latitude):\(longitude)" }
    }

    static func choices(near origin: CLLocation, ownPosts: [RealPost],
                        places: [MapTalkNearbyPlaceOption], currentUserID: UUID,
                        resolvePlaceIdentity: (UUID) -> UUID = { $0 }) -> [MapTalkPostLocationChoice] {
        // Compatibility entry point: directory results and POI identity
        // canonicalization deliberately cannot enter a Post history list.
        ownedChoices(ownPosts, currentUserID: currentUserID).map { choice in
            .init(id: choice.id, selection: choice.selection,
                  distanceMeters: PostLocationPolicy.isValid(origin.coordinate)
                    ? distance(choice.selection.coordinate, from: origin) : .infinity,
                  category: nil, previousPosts: choice.previousPosts, cachedThumbnail: choice.thumbnailURL)
        }
    }

    fileprivate static func ownedChoices(_ ownPosts: [RealPost], currentUserID: UUID) -> [MapTalkPostLocationChoice] {
        // Deduplicate before grouping so a repository/optimistic overlay copy
        // cannot become a second visit or keep a superseded coordinate alive.
        var seenPostIDs = Set<UUID>()
        let posts = ownPosts.filter {
            $0.userId == currentUserID && PostLocationPolicy.isValid($0.center)
        }.sorted { postPrecedes($0, $1) }.filter { seenPostIDs.insert($0.id).inserted }
        var histories: [CoordinateKey: [RealPost]] = [:]
        var identifiedHistories: [UUID: [RealPost]] = [:]
        for post in posts {
            if let identity = post.locationID {
                identifiedHistories[identity, default: []].append(post)
            } else {
                histories[CoordinateKey(post.center), default: []].append(post)
            }
        }
        // A legacy history choice seeds its first reusable identity from an
        // existing post ID. Subsequent posts can rejoin that history without
        // rewriting old records or merging unrelated explicit identities.
        for (key, history) in histories {
            guard let seed = history.map(\.id).min(by: { $0.uuidString < $1.uuidString }),
                  identifiedHistories[seed] != nil else { continue }
            identifiedHistories[seed] = ((identifiedHistories[seed] ?? []) + history).sorted { postPrecedes($0, $1) }
            histories.removeValue(forKey: key)
        }

        var results: [MapTalkPostLocationChoice] = []
        for (identity, history) in identifiedHistories {
            guard let latest = history.first else { continue }
            results.append(.init(id: "location:\(identity.uuidString.lowercased())",
                                 selection: .init(coordinate: latest.center, title: latest.locationName ?? "Previous post location",
                                                  locationName: latest.locationName, locationID: identity),
                                 distanceMeters: .infinity,
                                 category: nil, previousPosts: history, cachedThumbnail: history.lazy.compactMap { thumbnail($0) }.first))
        }
        for (key, history) in histories {
            guard let latest = history.first else { continue }
            results.append(.init(id: "history:\(key.identifier)",
                                 selection: .init(coordinate: latest.center, title: latest.locationName ?? "Previous post location",
                                                  locationName: latest.locationName,
                                                  locationID: history.map(\.id).min { $0.uuidString < $1.uuidString }),
                                 distanceMeters: .infinity,
                                 category: nil, previousPosts: history, cachedThumbnail: history.lazy.compactMap { thumbnail($0) }.first))
        }
        return results.sorted { lhs, rhs in
            let lhsDate = lhs.previousPosts.first?.activityDate ?? .distantPast
            let rhsDate = rhs.previousPosts.first?.activityDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }
    }

    fileprivate static func thumbnail(_ post: RealPost) -> URL? {
        for attachment in post.attachments {
            switch attachment.kind {
            case let .photo(url): return url
            case let .video(_, poster): if let poster { return poster }
            case .emoji: break
            }
        }
        return nil
    }

    private static func distance(_ coordinate: CLLocationCoordinate2D, from origin: CLLocation) -> CLLocationDistance {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: origin)
    }

    fileprivate static func coordinatePrecedes(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
        if lhs.latitude != rhs.latitude { return lhs.latitude < rhs.latitude }
        return lhs.longitude < rhs.longitude
    }

    private static func postPrecedes(_ lhs: RealPost, _ rhs: RealPost) -> Bool {
        if lhs.activityDate != rhs.activityDate { return lhs.activityDate > rhs.activityDate }
        if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
        return coordinatePrecedes(lhs.center, rhs.center)
    }
}
