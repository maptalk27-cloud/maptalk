import CoreLocation
import Foundation

/// Assigns observation and transition scores to map-matching candidates.
protocol ScoringEngineType: AnyObject {
    /// Returns the candidates sorted or annotated with scores based on sensor history and route metadata.
    func score(candidates: [MapMatchingCandidate],
               previous: MapMatchingCandidate?,
               elapsed: TimeInterval,
               speed: CLLocationSpeed,
               config: MapMatcher.Config) -> [MapMatchingCandidate]
}

final class ScoringEngine: ScoringEngineType {
    private let minSpeed: CLLocationSpeed = 0
    private let maxSpeed: CLLocationSpeed = 55 // ≈ 200 km/h

    func score(candidates: [MapMatchingCandidate],
               previous: MapMatchingCandidate?,
               elapsed: TimeInterval,
               speed: CLLocationSpeed,
               config: MapMatcher.Config) -> [MapMatchingCandidate] {
        guard !candidates.isEmpty else { return [] }

        let clampedSpeed = clamp(speed)
        let deltaTime = max(elapsed, 0.2) // impose minimum cadence for stability
        let expectedDeltaS = clamp(clampedSpeed * deltaTime,
                                   lower: clampedSpeed * 0.5,
                                   upper: clampedSpeed * 1.5)

        var scored: [MapMatchingCandidate] = []
        scored.reserveCapacity(candidates.count)

        for candidate in candidates {
            let weights = adjustedWeights(for: candidate, baseDistance: config.weightDistance, baseHeading: config.weightHeading)
            let emission = emissionScore(for: candidate,
                                         weights: weights,
                                         sigmaDistance: config.sigmaDistance,
                                         sigmaHeading: config.sigmaHeading)

            let transition = transitionScore(for: candidate,
                                             previous: previous,
                                             expectedDelta: expectedDeltaS,
                                             sigmaProgress: config.sigmaProgress,
                                             lambdaBacktrack: config.lambdaBacktrack,
                                             lambdaJump: config.lambdaJump,
                                             epsilonBacktrack: config.epsilonBacktrack)

            var enriched = candidate
            enriched.score = emission + transition
            enriched.emissionScore = emission
            enriched.transitionScore = transition
            scored.append(enriched)
        }

        scored.sort { ($0.score ?? .leastNonzeroMagnitude) > ($1.score ?? .leastNonzeroMagnitude) }
        return scored
    }

    private func emissionScore(for candidate: MapMatchingCandidate,
                               weights: (distance: Double, heading: Double),
                               sigmaDistance: Double,
                               sigmaHeading: Double) -> Double {
        let distanceTerm = exp(-pow(candidate.distanceFromRoute, 2) / (2 * pow(sigmaDistance, 2)))
        let headingTerm = exp(-pow(candidate.headingDifference, 2) / (2 * pow(sigmaHeading, 2)))
        return weights.distance * distanceTerm + weights.heading * headingTerm
    }

    private func transitionScore(for candidate: MapMatchingCandidate,
                                 previous: MapMatchingCandidate?,
                                 expectedDelta: CLLocationDistance,
                                 sigmaProgress: Double,
                                 lambdaBacktrack: Double,
                                 lambdaJump: Double,
                                 epsilonBacktrack: Double) -> Double {
        guard let previous else {
            return 0
        }

        let deltaS = candidate.progressAlongRoute - previous.progressAlongRoute
        let gaussian = exp(-pow(deltaS - expectedDelta, 2) / (2 * pow(sigmaProgress, 2)))

        var penalties = 0.0
        if deltaS < -epsilonBacktrack {
            penalties += lambdaBacktrack
        }

        if abs(candidate.stepIndex - previous.stepIndex) > 1 {
            penalties += lambdaJump
        }

        return gaussian - penalties
    }

    private func adjustedWeights(for candidate: MapMatchingCandidate,
                                 baseDistance: Double,
                                 baseHeading: Double) -> (distance: Double, heading: Double) {
        guard candidate.isNearFork else {
            return (baseDistance, baseHeading)
        }

        // Near forks we prefer continuity; reduce reliance on lateral distance.
        return (baseDistance * 0.6, baseHeading * 1.2)
    }

    private func clamp(_ speed: CLLocationSpeed) -> CLLocationSpeed {
        guard speed.isFinite else { return 0 }
        return max(minSpeed, min(speed, maxSpeed))
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        let lower = min(lower, upper)
        let upper = max(lower, upper)
        return max(lower, min(value, upper))
    }
}
