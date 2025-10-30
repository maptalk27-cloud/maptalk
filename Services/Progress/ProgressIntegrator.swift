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
