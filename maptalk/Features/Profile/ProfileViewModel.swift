import Combine
import MapKit

@MainActor
final class ProfileViewModel: ObservableObject {
    enum Context: Equatable, Identifiable {
        case me
        case friend(User)

        var id: UUID {
            user.id
        }

        var user: User {
            switch self {
            case .me:
                return PreviewData.currentUser
            case let .friend(user):
                return user
            }
        }

        var isCurrentUser: Bool {
            if case .me = self { return true }
            return false
        }

        var usesChengsiFeed: Bool {
            if case .me = self { return true }
            return false
        }
    }

    struct Identity {
        let user: User
        let isCurrentUser: Bool

        var displayName: String { user.handle }
        var subtitle: String {
            isCurrentUser ? "Live map journal" : "Shared map journal"
        }
    }

    struct Summary {
        let footprintCount: Int
        let reelCount: Int
        let categoryCount: Int

        static let empty = Summary(footprintCount: 0, reelCount: 0, categoryCount: 0)
    }

    struct Persona {
        let baseCity: String
        let bio: String
        let mood: String
        let interests: [VisitTag]
    }

    struct Footprint: Identifiable {
        let ratedPOI: RatedPOI
        let visits: [RatedPOI.CheckIn]

        var id: UUID { ratedPOI.id }
        var name: String { ratedPOI.poi.name }
        var category: POICategory { ratedPOI.poi.category }
        var coordinate: CLLocationCoordinate2D { ratedPOI.poi.coordinate }
        var latestVisit: Date? { visits.max(by: { $0.createdAt < $1.createdAt })?.createdAt }
        var totalVisits: Int { visits.count }
    }

    struct MapPin: Identifiable {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let category: POICategory
        let visitCount: Int
    }

    @Published private(set) var identity: Identity
    @Published private(set) var summary: Summary = .empty
    @Published private(set) var persona: Persona = Persona(
        baseCity: "Seattle, WA",
        bio: "",
        mood: "",
        interests: []
    )
    @Published private(set) var footprints: [Footprint] = []
    @Published private(set) var reels: [RealPost] = []
    @Published private(set) var mapRegion: MKCoordinateRegion = ProfileViewModel.defaultRegion

    var mapPins: [MapPin] {
        footprints.map { footprint in
            MapPin(
                id: footprint.id,
                coordinate: footprint.coordinate,
                category: footprint.category,
                visitCount: footprint.totalVisits
            )
        }
    }

    private let environment: AppEnvironment
    private let context: Context

    init(environment: AppEnvironment, context: Context = .me) {
        self.environment = environment
        self.context = context
        self.identity = Identity(user: context.user, isCurrentUser: context.isCurrentUser)
        loadSnapshot()
    }

    func refresh() {
        loadSnapshot()
    }

    private func loadSnapshot() {
        let user = context.user
        if case .me = context {
            let chengsiFeed = PreviewData.chengsi
            loadFeed(chengsiFeed)
            return
        }

        let ratedPOIs = PreviewData.sampleRatedPOIs
        let matchedFootprints: [Footprint] = ratedPOIs.compactMap { rated in
            let visits = rated.checkIns.filter { $0.userId == user.id }
            guard visits.isEmpty == false else { return nil }
            return Footprint(ratedPOI: rated, visits: visits)
        }

        footprints = matchedFootprints
            .sorted { ($0.latestVisit ?? .distantPast) > ($1.latestVisit ?? .distantPast) }

        let personalReals = PreviewData.sampleReals
            .filter { $0.userId == user.id }
            .sorted { $0.createdAt > $1.createdAt }
        reels = personalReals

        summary = Summary(
            footprintCount: matchedFootprints.count,
            reelCount: personalReals.count,
            categoryCount: Set(matchedFootprints.map { $0.category }).count
        )

        persona = Persona(
            baseCity: "Seattle, WA",
            bio: personaBio(for: user),
            mood: personaMood(for: user),
            interests: topTags(from: matchedFootprints)
        )

        if let region = Self.region(for: matchedFootprints) {
            mapRegion = region
        } else {
            mapRegion = Self.defaultRegion
        }
    }

    private func loadFeed(_ feed: PreviewData.ChengsiMock) {
        let ratedForProfile = PreviewData.profileRatedPOIs(for: feed.user, customPOIs: feed.pois)
        let matchedFootprints: [Footprint] = ratedForProfile.map { rated in
            Footprint(ratedPOI: rated, visits: rated.checkIns)
        }

        footprints = matchedFootprints
            .sorted { ($0.latestVisit ?? .distantPast) > ($1.latestVisit ?? .distantPast) }

        reels = feed.reels

        summary = Summary(
            footprintCount: matchedFootprints.count,
            reelCount: feed.reels.count,
            categoryCount: Set(matchedFootprints.map { $0.category }).count
        )

        persona = Persona(
            baseCity: "Seattle, WA",
            bio: personaBio(for: feed.user),
            mood: personaMood(for: feed.user),
            interests: topTags(from: matchedFootprints)
        )

        if let region = Self.region(for: matchedFootprints) {
            mapRegion = region
        } else {
            mapRegion = Self.defaultRegion
        }
    }

    private func personaBio(for user: User) -> String {
        if user.id == PreviewData.currentUser.id {
            return "Sketching neon detours & POI reels in realtime."
        }
        return "@\(user.handle) shares their favorite detours and reels here."
    }

    private func personaMood(for user: User) -> String {
        if user.id == PreviewData.currentUser.id {
            return "Night market scout"
        }
        let handles = ["Skyline chaser", "Late espresso seeker", "Waterfront storyteller"]
        return handles.absorbingHash(of: user.id) ?? "City explorer"
    }

    private func topTags(from footprints: [Footprint]) -> [VisitTag] {
        var counts: [VisitTag: Int] = [:]
        for footprint in footprints {
            for visit in footprint.visits {
                if let tag = visit.tag {
                    counts[tag, default: 0] += 1
                }
            }
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
    }

    private static func region(for footprints: [Footprint]) -> MKCoordinateRegion? {
        guard footprints.isEmpty == false else { return nil }
        let lats = footprints.map { $0.coordinate.latitude }
        let lons = footprints.map { $0.coordinate.longitude }
        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else { return nil }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let latSpan = max(maxLat - minLat, 0.02)
        let lonSpan = max(maxLon - minLon, 0.02)
        let span = MKCoordinateSpan(latitudeDelta: latSpan * 1.6, longitudeDelta: lonSpan * 1.6)
        return MKCoordinateRegion(center: center, span: span)
    }

    private static var defaultRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33),
            latitudinalMeters: 45_000,
            longitudinalMeters: 45_000
        )
    }
}

private extension Array where Element == String {
    func absorbingHash(of id: UUID) -> String? {
        guard isEmpty == false else { return nil }
        let hash = id.uuidString.hashValue
        let index = abs(hash) % count
        return self[index]
    }
}
