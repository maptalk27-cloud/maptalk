import Foundation

/// Assigns observation and transition scores to map-matching candidates.
protocol ScoringEngineType: AnyObject {
    /// Returns the candidates sorted or annotated with scores based on sensor history and route metadata.
    func score(candidates: [MapMatchingCandidate],
               previous: MapMatchingCandidate?) -> [MapMatchingCandidate]
}
