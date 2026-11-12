import CoreLocation
import Foundation

/// A Post's chosen subject location, not a claim about a live POI check-in.
struct MapTalkPostLocationSelection {
    let coordinate: CLLocationCoordinate2D
    let title: String
    /// A display fallback such as “Previous post location” is not a place name.
    var locationName: String? = nil
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

    var postCount: Int { previousPosts.count }
    var isPOI: Bool { category != nil }
    var ownCheckInCount: Int { placeOption?.ownCheckIns.count ?? 0 }
    var hasHistory: Bool { !previousPosts.isEmpty || placeOption?.hasHistory == true }
    var lastOwnActivityAt: Date? {
        (previousPosts.map(\.activityDate) + (placeOption?.ownCheckIns.map(\.activityDate) ?? [])).max()
    }
    var historyPriority: Int {
        if !previousPosts.isEmpty || ownCheckInCount > 0 { return 0 }
        return placeOption?.historyPriority ?? 2
    }
    var thumbnailURL: URL? {
        for post in previousPosts {
            for attachment in post.attachments {
                switch attachment.kind {
                case let .photo(url): return url
                case let .video(_, poster):
                    if let poster { return poster }
                case .emoji: break
                }
            }
        }
        return nil
    }
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
                        places: [MapTalkNearbyPlaceOption], currentUserID: UUID) -> [MapTalkPostLocationChoice] {
        guard PostLocationPolicy.isValid(origin.coordinate) else { return [] }

        // Deduplicate before grouping so a repository/optimistic overlay copy
        // cannot become a second visit or keep a superseded coordinate alive.
        var seenPostIDs = Set<UUID>()
        let posts = ownPosts.filter {
            $0.userId == currentUserID && PostLocationPolicy.isValid($0.center)
        }.sorted(by: postPrecedes).filter { seenPostIDs.insert($0.id).inserted }
        var histories: [CoordinateKey: [RealPost]] = [:]
        for post in posts {
            guard PostLocationPolicy.location(for: .init(coordinate: post.center, title: ""), near: origin) != nil else {
                continue
            }
            histories[CoordinateKey(post.center), default: []].append(post)
        }

        var seenPlaceIDs = Set<UUID>()
        let uniquePlaces = places.filter {
            PostLocationPolicy.location(for: .init(coordinate: $0.place.poi.coordinate, title: ""), near: origin) != nil
        }.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
            if lhs.place.poi.name != rhs.place.poi.name { return lhs.place.poi.name < rhs.place.poi.name }
            return coordinatePrecedes(lhs.place.poi.coordinate, rhs.place.poi.coordinate)
        }.filter { seenPlaceIDs.insert($0.id).inserted }
        let placesByCoordinate = Dictionary(grouping: uniquePlaces) { CoordinateKey($0.place.poi.coordinate) }

        var results: [MapTalkPostLocationChoice] = uniquePlaces.map { option in
            let poi = option.place.poi
            let key = CoordinateKey(poi.coordinate)
            // Co-located venues (e.g. hotel and restaurant) remain separate.
            // A nearby coordinate is never enough to infer a venue identity.
            let candidateHistory = histories[key] ?? []
            let matchesOriginalCoordinates = candidateHistory.allSatisfy {
                $0.center.latitude == poi.coordinate.latitude && $0.center.longitude == poi.coordinate.longitude
            }
            let history = placesByCoordinate[key]?.count == 1 && matchesOriginalCoordinates
                ? histories.removeValue(forKey: key) ?? [] : []
            let coordinate = history.first?.center ?? poi.coordinate
            return .init(id: "poi:\(poi.id.uuidString.lowercased())",
                         selection: .init(coordinate: coordinate, title: history.first?.locationName ?? poi.name,
                                          locationName: history.first?.locationName),
                         distanceMeters: distance(coordinate, from: origin),
                         category: poi.category, previousPosts: history, placeOption: option)
        }
        for (key, history) in histories {
            guard let latest = history.first else { continue }
            results.append(.init(id: "history:\(key.identifier)",
                                 selection: .init(coordinate: latest.center, title: latest.locationName ?? "Previous post location",
                                                  locationName: latest.locationName),
                                 distanceMeters: distance(latest.center, from: origin),
                                 category: nil, previousPosts: history))
        }
        return results.sorted { lhs, rhs in
            if lhs.historyPriority != rhs.historyPriority { return lhs.historyPriority < rhs.historyPriority }
            if lhs.distanceMeters != rhs.distanceMeters { return lhs.distanceMeters < rhs.distanceMeters }
            return lhs.id < rhs.id
        }
    }

    private static func distance(_ coordinate: CLLocationCoordinate2D, from origin: CLLocation) -> CLLocationDistance {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude).distance(from: origin)
    }

    private static func coordinatePrecedes(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Bool {
        if lhs.latitude != rhs.latitude { return lhs.latitude < rhs.latitude }
        return lhs.longitude < rhs.longitude
    }

    private static func postPrecedes(_ lhs: RealPost, _ rhs: RealPost) -> Bool {
        if lhs.activityDate != rhs.activityDate { return lhs.activityDate > rhs.activityDate }
        if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
        return coordinatePrecedes(lhs.center, rhs.center)
    }
}
