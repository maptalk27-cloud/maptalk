import Combine
import Foundation
import MapKit

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
    @Published var userCoordinate: CLLocationCoordinate2D?

    let scope: Scope
    private let environment: AppEnvironment
    init(environment: AppEnvironment, scope: Scope = .global) {
        self.environment = environment
        self.scope = scope
        switch scope {
        case .global:
            bind()
        case let .user(user):
            loadUserScope(for: user)
        }
    }

    func onAppear() {
        if case .global = scope {
            environment.location.requestWhenInUse()
        }
    }

    func centerOnUser() {
        guard let location = environment.location.location.value else { return }
        let span = region.span
        region = MKCoordinateRegion(center: location.coordinate, span: span)
    }

    func user(for id: UUID) -> User? {
        if case let .user(user) = scope, user.id == id {
            return user
        }
        return PreviewData.user(for: id)
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

    func region(for real: RealPost) -> MKCoordinateRegion {
        regionAround(
            coordinate: real.center,
            radiusMeters: real.radiusMeters,
            minimumRadius: 3_500
        )
    }

    func focus(on real: RealPost) {
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
        region = region(for: journey)
    }

    private func bind() {
        let coordinateStream = environment.location.location
            .compactMap { $0?.coordinate }
            .share()

        coordinateStream
            .map(Optional.init)
            .receive(on: DispatchQueue.main)
            .assign(to: &$userCoordinate)

        coordinateStream
            .flatMap { [environment] coordinate in
                environment.poiRepo.near(coordinate)
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$ratedPOIs)

        environment.realRepo
            .active(in: nil)
            .receive(on: DispatchQueue.main)
            .assign(to: &$reals)
    }

    private func loadUserScope(for user: User) {
        let snapshot = UserMapViewModel(
            environment: environment,
            context: .profileContext(for: user)
        )
        ratedPOIs = snapshot.footprints.map(\.ratedPOI)
        reals = snapshot.reels
        userCoordinate = nil
        region = snapshot.mapRegion
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
