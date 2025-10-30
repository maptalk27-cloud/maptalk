import CoreLocation
import Foundation

/// Projects the current location onto nearby route segments, producing multiple candidate positions.
protocol CandidateGeneratorType: AnyObject {
    /// Returns ordered candidates representing potential on-route positions for the supplied location.
    func generateCandidates(for location: CLLocation,
                            corridor: [CLLocationCoordinate2D]) -> [MapMatchingCandidate]
}
