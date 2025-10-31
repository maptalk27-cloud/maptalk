import Combine
import Foundation
import MapKit

/// Computes user progress along the active route using snapped locations.
protocol ProgressIntegratorType: AnyObject {
    /// Emits derived progress metrics such as distance traveled and step index.
    var progressUpdates: AnyPublisher<RouteProgress, Never> { get }

    /// Updates internal references when the active route changes.
    func update(route: MKRoute?)

    /// Integrates the latest enhanced location into cumulative progress metrics.
    func ingest(enhancedLocation: EnhancedLocation)

    /// Clears cached accumulators and progress state.
    func reset()
}

final class ProgressIntegrator: ProgressIntegratorType {
    private let subject = PassthroughSubject<RouteProgress, Never>()
    private var route: MKRoute?
    private var routeDistance: CLLocationDistance = 0
    private var lastProgress: CLLocationDistance?

    var progressUpdates: AnyPublisher<RouteProgress, Never> {
        subject.eraseToAnyPublisher()
    }

    func update(route: MKRoute?) {
        self.route = route
        routeDistance = route?.distance ?? 0
        lastProgress = nil
    }

    func ingest(enhancedLocation: EnhancedLocation) {
        guard routeDistance > 0 else { return }

        let rawProgress = enhancedLocation.candidate.progressAlongRoute
        let clampedProgress: CLLocationDistance
        if let last = lastProgress {
            clampedProgress = max(rawProgress, last)
        } else {
            clampedProgress = max(0, rawProgress)
        }

        let distanceTraveled = clampedProgress
        let distanceRemaining = max(0, routeDistance - distanceTraveled)
        let fraction = routeDistance > 0 ? min(1, distanceTraveled / routeDistance) : 0
        let progress = RouteProgress(distanceTraveled: distanceTraveled,
                                     distanceRemaining: distanceRemaining,
                                     fractionTraveled: fraction,
                                     stepIndex: enhancedLocation.candidate.stepIndex)

        lastProgress = clampedProgress
        subject.send(progress)
    }

    func reset() {
        route = nil
        routeDistance = 0
        lastProgress = nil
    }
}
