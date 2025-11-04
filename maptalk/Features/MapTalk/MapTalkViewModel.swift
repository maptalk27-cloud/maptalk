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

    private func bind() {
        let coordinateStream = environment.location.location
            .compactMap { $0?.coordinate }
            .share()

        coordinateStream
            .map(Optional.init)
            .receive(on: DispatchQueue.main)
            .assign(to: &$userCoordinate)

        let poiStream = coordinateStream
            .flatMap { [environment] coordinate in
                environment.poiRepo.near(coordinate)
            }
            .share()

        poiStream
            .combineLatest(
                environment.ratingRepo
                    .recent(in: nil)
            )
            .map { pois, ratings -> [RatedPOI] in
                let grouped = Dictionary(grouping: ratings, by: \.poiId)
                return pois.compactMap { poi in
                    guard let ratings = grouped[poi.id], ratings.isEmpty == false else { return nil }
                    return RatedPOI(poi: poi, ratings: ratings)
                }
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$ratedPOIs)

        environment.realRepo
            .active(in: nil)
            .receive(on: DispatchQueue.main)
            .assign(to: &$reals)
    }
}
