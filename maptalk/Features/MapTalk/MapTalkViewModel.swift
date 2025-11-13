import Combine
import Foundation
import MapKit

@MainActor
final class MapTalkViewModel: ObservableObject {
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

    private let environment: AppEnvironment
    init(environment: AppEnvironment) {
        self.environment = environment
        bind()
    }

    func onAppear() {
        environment.location.requestWhenInUse()
    }

    func centerOnUser() {
        guard let location = environment.location.location.value else { return }
        let span = region.span
        region = MKCoordinateRegion(center: location.coordinate, span: span)
    }

    func user(for id: UUID) -> User? {
        PreviewData.user(for: id)
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
