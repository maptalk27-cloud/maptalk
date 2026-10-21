import Combine
import Foundation
import MapKit

@MainActor
final class UserProfileViewModel: ObservableObject {
    struct ProfileStats {
        let following: Int
        let poi: Int
        let reels: Int
    }

    struct ProfileDraft {
        var handle: String
        var baseCity: String
        var bio: String
        var mood: String
    }

    struct HistoryActivity: Identifiable {
        enum Kind {
            case reel(RealPost)
            case poi(UserMapViewModel.Footprint)
        }

        enum Preview {
            case image(URL)
            case video(URL?)
            case category(POICategory)
        }

        let id: UUID
        let kind: Kind
        let title: String
        let subtitle: String
        let timestamp: Date
        let preview: Preview
        let timelineSegmentId: String?
    }

    let environment: AppEnvironment
    let context: UserMapViewModel.Context

    @Published private(set) var user: User
    @Published private(set) var summary: UserMapViewModel.Summary
    @Published private(set) var persona: UserMapViewModel.Persona
    @Published private(set) var footprints: [UserMapViewModel.Footprint]
    @Published private(set) var reels: [RealPost]
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoadFailure = false
    @Published var issue: String?

    private let snapshot: UserMapViewModel
    private var snapshotCancellables = Set<AnyCancellable>()

    init(environment: AppEnvironment, context: UserMapViewModel.Context) {
        self.environment = environment
        self.context = if environment.backend != nil,
            context.isCurrentUser || context.user.id == environment.currentUser.id {
            .me
        } else {
            context
        }
        self.snapshot = UserMapViewModel(environment: environment, context: context)
        self.user = snapshot.identity.user
        self.summary = snapshot.summary
        self.persona = snapshot.persona
        self.footprints = snapshot.footprints
        self.reels = snapshot.reels
        bindSnapshot()
    }

    var isCurrentUser: Bool {
        context.isCurrentUser
    }

    var navigationTitle: String {
        isCurrentUser ? "Profile" : user.handle
    }

    var relationshipLabel: String {
        isCurrentUser ? "Your public map identity" : "Shared map identity"
    }

    var stats: ProfileStats {
        ProfileStats(
            following: environment.backend != nil ? 0 : (isCurrentUser ? min(PreviewData.sampleFriends.count, 88) : mockCount(seed: 41, base: 12, range: 72)),
            poi: footprints.count,
            reels: reels.count
        )
    }

    var primaryActionTitle: String {
        isCurrentUser ? "Edit Profile" : "Message"
    }

    var primaryActionIcon: String {
        isCurrentUser ? "square.and.pencil" : "message.fill"
    }

    var mapRegion: MKCoordinateRegion {
        snapshot.mapRegion
    }

    var mapPins: [UserMapViewModel.MapPin] {
        snapshot.mapPins
    }

    var historyActivities: [HistoryActivity] {
        let reelActivities = reels.map { real in
            HistoryActivity(
                id: real.id,
                kind: .reel(real),
                title: real.message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Reel",
                subtitle: locationLabel(for: real.id, coordinate: real.center),
                timestamp: real.createdAt,
                preview: preview(for: real),
                timelineSegmentId: timelineSegmentId(for: real.id)
            )
        }

        let poiActivities = footprints.map { footprint in
            HistoryActivity(
                id: footprint.id,
                kind: .poi(footprint),
                title: footprint.name,
                subtitle: locationLabel(for: footprint.ratedPOI.poi.id, coordinate: footprint.coordinate),
                timestamp: footprint.latestVisit ?? .distantPast,
                preview: preview(for: footprint.ratedPOI),
                timelineSegmentId: timelineSegmentId(for: footprint.id)
            )
        }

        return (reelActivities + poiActivities)
            .sorted { $0.timestamp > $1.timestamp }
    }

    func makeDraft() -> ProfileDraft {
        ProfileDraft(
            handle: user.handle,
            baseCity: persona.baseCity,
            bio: persona.bio,
            mood: persona.mood
        )
    }

    func saveProfile(_ draft: ProfileDraft) {
        guard environment.backend == nil else {
            issue = "Profile editing isn't connected yet. Your account hasn't been changed."
            return
        }
        let cleanHandle = draft.handle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        let nextHandle = cleanHandle.isEmpty ? user.handle : cleanHandle
        user.handle = nextHandle
        persona = UserMapViewModel.Persona(
            baseCity: draft.baseCity.trimmingCharacters(in: .whitespacesAndNewlines),
            bio: draft.bio.trimmingCharacters(in: .whitespacesAndNewlines),
            mood: draft.mood.trimmingCharacters(in: .whitespacesAndNewlines),
            interests: persona.interests
        )
    }

    func saveConnectedProfile(handle: String, avatarData: Data?) async throws {
        guard isCurrentUser, let backend = environment.backend else { return }
        try await backend.updateProfile(handle: handle, avatarData: avatarData)
        if let warning = backend.issue, warning.hasPrefix("Your profile was saved.") {
            issue = warning
        }
        // The shared store publishes the accepted identity to the profile, MyMap and tab.
        // Do not optimistically update it before the server accepts the change.
    }

    func userProvider(for id: UUID) -> User? {
        if id == user.id {
            return user
        }
        return environment.user(for: id)
    }

    var canEditProfile: Bool { isCurrentUser }
    var hasConnectedAccount: Bool { environment.backend != nil }

    func explainUnavailableSocialActions() {
        issue = "Chat and following aren't connected yet. You can view this person's public posts and map."
    }

    func refreshFromBackend(force: Bool = true) async {
        await snapshot.refreshFromBackend(force: force)
    }

    private func bindSnapshot() {
        snapshot.$identity
            .map(\.user)
            .assign(to: &$user)
        snapshot.$summary.assign(to: &$summary)
        snapshot.$persona.assign(to: &$persona)
        snapshot.$footprints.assign(to: &$footprints)
        snapshot.$reels.assign(to: &$reels)
        snapshot.$isRefreshing.assign(to: &$isRefreshing)
        snapshot.$hasLoadFailure.assign(to: &$hasLoadFailure)
        snapshot.$issue
            .sink { [weak self] issue in self?.issue = issue }
            .store(in: &snapshotCancellables)
    }

    private func preview(for real: RealPost) -> HistoryActivity.Preview {
        for attachment in real.attachments {
            switch attachment.kind {
            case let .photo(url):
                return .image(url)
            case let .video(_, poster):
                return .video(poster)
            case .emoji:
                continue
            }
        }
        return .video(nil)
    }

    private func preview(for rated: RatedPOI) -> HistoryActivity.Preview {
        for media in rated.media {
            switch media.kind {
            case let .photo(url):
                return .image(url)
            case let .video(_, poster):
                return .video(poster)
            }
        }

        for checkIn in rated.checkIns {
            for media in checkIn.media {
                switch media.kind {
                case let .photo(url):
                    return .image(url)
                case let .video(_, poster):
                    return .video(poster)
                }
            }
        }

        return .category(rated.poi.category)
    }

    private func timelineSegmentId(for eventId: UUID) -> String? {
        timelineSegments.first { segment in
            segment.events.contains { $0.id == eventId }
        }?.id
    }

    private var timelineSegments: [TimelineSegment] {
        let reelEvents = reels.map { real in
            TimelineEvent(
                id: real.id,
                date: real.createdAt,
                coordinate: real.center,
                kind: .reel(real, userProvider(for: real.userId))
            )
        }

        let footprintEvents: [TimelineEvent] = footprints.compactMap { footprint in
            guard let date = footprint.latestVisit else { return nil }
            return TimelineEvent(
                id: footprint.id,
                date: date,
                coordinate: footprint.coordinate,
                kind: .poi(footprint.ratedPOI)
            )
        }

        let events = (reelEvents + footprintEvents).sorted { $0.date > $1.date }
        var segments: [TimelineSegment] = []
        for event in events {
            let label = locationLabel(for: event.id, coordinate: event.coordinate, preferred: event.labelHint)
            if var last = segments.last, last.label == label {
                last.events.append(event)
                last.end = max(last.end, event.date)
                segments[segments.count - 1] = last
            } else {
                segments.append(
                    TimelineSegment(
                        label: label,
                        start: event.date,
                        end: event.date,
                        events: [event]
                    )
                )
            }
        }
        return segments
    }

    private func locationLabel(for id: UUID, coordinate: CLLocationCoordinate2D, preferred: String? = nil) -> String {
        if let preferred, preferred.isEmpty == false {
            return preferred
        }
        if environment.backend == nil, let registered = PreviewData.locationLabel(for: id) {
            return registered
        }
        return fallbackLabel(for: coordinate)
    }

    private func fallbackLabel(for coordinate: CLLocationCoordinate2D) -> String {
        guard environment.backend == nil else {
            return String(format: "%.3f, %.3f", coordinate.latitude, coordinate.longitude)
        }
        let candidates: [(String, CLLocationCoordinate2D)] = [
            ("Xi'an, Shaanxi, China", .init(latitude: 34.341, longitude: 108.939)),
            ("Hangzhou, Zhejiang, China", .init(latitude: 30.274, longitude: 120.155)),
            ("Suzhou, Jiangsu, China", .init(latitude: 31.298, longitude: 120.583)),
            ("Seattle, Washington, USA", .init(latitude: 47.6062, longitude: -122.3321))
        ]

        let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best: (String, CLLocationDistance)?
        for candidate in candidates {
            let distance = current.distance(
                from: CLLocation(latitude: candidate.1.latitude, longitude: candidate.1.longitude)
            )
            if best == nil || distance < best!.1 {
                best = (candidate.0, distance)
            }
        }

        if let best, best.1 < 600_000 {
            return best.0
        }
        return String(format: "Lat %.3f, Lon %.3f", coordinate.latitude, coordinate.longitude)
    }

    private func mockCount(seed: Int, base: Int, range: Int) -> Int {
        let total = user.id.uuidString.unicodeScalars.reduce(seed) { partial, scalar in
            partial &+ Int(scalar.value)
        }
        return base + abs(total % max(range, 1))
    }
}

extension UserMapViewModel.Context {
    static func profileContext(for user: User) -> UserMapViewModel.Context {
        user.id == PreviewData.currentUser.id ? .me : .friend(user)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
