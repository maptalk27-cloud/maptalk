import Combine
import CoreLocation
import Foundation
import MapKit

/// Actor that coordinates the map-matching pipeline and publishes enhanced locations.
protocol MapMatcherType: AnyObject {
    /// Emits snapped location updates with confidence metadata for UI consumption.
    var enhancedLocations: AnyPublisher<EnhancedLocation, Never> { get }

    /// Configures the matcher for a new route, resetting any cached corridor or scoring state.
    func update(route: MKRoute?)

    /// Accepts a normalized location from the feed and triggers the matching pipeline.
    func ingest(normalizedLocation: CLLocation)

    /// Clears cached state such as the previous candidate or dead-reckoning flags.
    func reset()
}

actor MapMatcher: MapMatcherType {
    struct Config: Equatable {
        let sigmaDistance: Double
        let sigmaHeading: Double
        let sigmaProgress: Double
        let lambdaBacktrack: Double
        let lambdaJump: Double
        let epsilonBacktrack: Double
        let weightDistance: Double
        let weightHeading: Double
        let maxCandidates: Int
        let corridorWindowLength: CLLocationDistance
        let nearForkRadius: CLLocationDistance
        let deadReckoningBlendDuration: TimeInterval
        let positionAlpha: Double
        let headingAlpha: Double
        let backtrackAcceptanceFrames: Int
        let deadReckoningAccuracyThreshold: CLLocationAccuracy
        let deadReckoningGapThreshold: TimeInterval
        let deadReckoningMaxDistance: CLLocationDistance

        static let defaultHighwaySpeedThreshold: CLLocationSpeed = 70.0 / 3.6

        static let city = Config(
            sigmaDistance: 8,
            sigmaHeading: 20,
            sigmaProgress: 15,
            lambdaBacktrack: 4,
            lambdaJump: 6,
            epsilonBacktrack: 3,
            weightDistance: 2,
            weightHeading: 1,
            maxCandidates: 5,
            corridorWindowLength: 400,
            nearForkRadius: 80,
            deadReckoningBlendDuration: 0.75,
            positionAlpha: 0.22,
            headingAlpha: 0.28,
            backtrackAcceptanceFrames: 5,
            deadReckoningAccuracyThreshold: 35,
            deadReckoningGapThreshold: 1.2,
            deadReckoningMaxDistance: 30
        )

        static let highway = Config(
            sigmaDistance: 6,
            sigmaHeading: 15,
            sigmaProgress: 12,
            lambdaBacktrack: 4,
            lambdaJump: 6,
            epsilonBacktrack: 3,
            weightDistance: 1.5,
            weightHeading: 1,
            maxCandidates: 5,
            corridorWindowLength: 800,
            nearForkRadius: 80,
            deadReckoningBlendDuration: 0.75,
            positionAlpha: 0.18,
            headingAlpha: 0.24,
            backtrackAcceptanceFrames: 5,
            deadReckoningAccuracyThreshold: 45,
            deadReckoningGapThreshold: 1.4,
            deadReckoningMaxDistance: 45
        )
    }

    private let corridorProvider: CorridorProviderType
    private let candidateGenerator: CandidateGeneratorType
    private let scoringEngine: ScoringEngineType
    private let enhancedSubject = PassthroughSubject<EnhancedLocation, Never>()

    private var activeConfig: Config
    private var highwaySpeedThreshold: CLLocationSpeed
    private var previousCandidate: MapMatchingCandidate?
    private var previousEnhanced: EnhancedLocation?
    private var previousTimestamp: Date?
    private var backtrackFrameCounter = 0
    private var deadReckoningState: DeadReckoningState?
    private var diagnostics = Diagnostics()

    init(corridorProvider: CorridorProviderType,
         candidateGenerator: CandidateGeneratorType,
         scoringEngine: ScoringEngineType,
         initialConfig: Config = .city,
         highwaySpeedThreshold: CLLocationSpeed = Config.defaultHighwaySpeedThreshold) {
        self.corridorProvider = corridorProvider
        self.candidateGenerator = candidateGenerator
        self.scoringEngine = scoringEngine
        self.activeConfig = initialConfig
        self.highwaySpeedThreshold = highwaySpeedThreshold
        corridorProvider.update(windowLength: initialConfig.corridorWindowLength)
    }

    nonisolated var enhancedLocations: AnyPublisher<EnhancedLocation, Never> {
        enhancedSubject.eraseToAnyPublisher()
    }

    func update(route: MKRoute?) {
        corridorProvider.update(route: route)
        resetInternalState()
    }

    func ingest(normalizedLocation: CLLocation) {
        selectConfig(for: normalizedLocation.speed)
        let timestamp = normalizedLocation.timestamp
        let elapsed = timeIntervalSincePrevious(timestamp)

        corridorProvider.refreshCorridor(around: normalizedLocation.coordinate)
        let segments = corridorProvider.windowSegments()

        if shouldEnterDeadReckoning(for: normalizedLocation,
                                    segments: segments,
                                    elapsed: elapsed),
           let deadReckoned = produceDeadReckonedLocation(from: normalizedLocation, elapsed: elapsed) {
            previousTimestamp = timestamp
            enhancedSubject.send(deadReckoned)
            return
        } else if deadReckoningState != nil {
            if deadReckoningState?.blendAnchor == nil {
                deadReckoningState?.blendAnchor = deadReckoningState?.lastPrediction
                deadReckoningState?.blendStartedAt = timestamp
            }
        }

        guard !segments.isEmpty else {
            previousTimestamp = timestamp
            return
        }

        var candidates = candidateGenerator.generateCandidates(for: normalizedLocation,
                                                               segments: segments,
                                                               config: activeConfig)

        guard !candidates.isEmpty else {
            previousTimestamp = timestamp
            return
        }

        let scored = scoringEngine.score(candidates: candidates,
                                         previous: previousCandidate,
                                         elapsed: elapsed,
                                         speed: normalizedLocation.speed,
                                         config: activeConfig)

        guard var bestCandidate = scored.first else {
            previousTimestamp = timestamp
            return
        }

        let regulatedProgress = regulateProgress(for: bestCandidate)
        bestCandidate.progressAlongRoute = regulatedProgress

        let confidenceValue = confidence(from: scored)

        let expectedDisplacement = expectedTravelDistance(speed: normalizedLocation.speed, elapsed: elapsed)
        var smoothingResult = smooth(candidate: bestCandidate,
                                     rawLocation: normalizedLocation,
                                     expectedDisplacement: expectedDisplacement,
                                     elapsed: elapsed)

        if let blendAnchor = deadReckoningState?.blendAnchor,
           let blendStart = deadReckoningState?.blendStartedAt {
            let factor = blendFactor(for: timestamp.timeIntervalSince(blendStart))
            smoothingResult.coordinate = interpolateCoordinate(from: blendAnchor.coordinate,
                                                               to: smoothingResult.coordinate,
                                                               factor: factor)
            if let anchorHeading = blendAnchor.heading,
               let currentHeading = smoothingResult.heading {
                smoothingResult.heading = smoothHeading(previous: anchorHeading,
                                                        newHeading: currentHeading,
                                                        alpha: factor)
            }
            if factor >= 1 {
                deadReckoningState = nil
            }
        }

        let enhanced = EnhancedLocation(
            coordinate: smoothingResult.coordinate,
            heading: smoothingResult.heading,
            speed: smoothingResult.speed,
            timestamp: timestamp,
            confidence: confidenceValue,
            candidate: bestCandidate
        )

        updateDiagnostics(with: enhanced, candidate: bestCandidate)

        previousCandidate = bestCandidate
        previousEnhanced = enhanced
        previousTimestamp = timestamp

        enhancedSubject.send(enhanced)
    }

    func reset() {
        corridorProvider.update(route: nil)
        resetInternalState()
    }

    private func selectConfig(for speed: CLLocationSpeed) {
        let newConfig: Config
        guard speed.isFinite, speed >= 0 else {
            newConfig = .city
            applyConfigIfNeeded(newConfig)
            return
        }

        newConfig = speed > highwaySpeedThreshold ? .highway : .city
        applyConfigIfNeeded(newConfig)
    }

    private func applyConfigIfNeeded(_ newConfig: Config) {
        guard newConfig != activeConfig else { return }
        activeConfig = newConfig
        corridorProvider.update(windowLength: newConfig.corridorWindowLength)
    }

    private func resetInternalState() {
        previousCandidate = nil
        previousEnhanced = nil
        previousTimestamp = nil
        backtrackFrameCounter = 0
        deadReckoningState = nil
        diagnostics = Diagnostics()
    }

    private func timeIntervalSincePrevious(_ timestamp: Date) -> TimeInterval {
        guard let previousTimestamp else { return 0 }
        return max(0, timestamp.timeIntervalSince(previousTimestamp))
    }

    private func regulateProgress(for candidate: MapMatchingCandidate) -> CLLocationDistance {
        guard let previousCandidate else {
            backtrackFrameCounter = 0
            return candidate.progressAlongRoute
        }

        let delta = candidate.progressAlongRoute - previousCandidate.progressAlongRoute
        if delta >= 0 {
            backtrackFrameCounter = 0
            return candidate.progressAlongRoute
        }

        if abs(delta) <= activeConfig.epsilonBacktrack {
            backtrackFrameCounter = 0
            return candidate.progressAlongRoute
        }

        backtrackFrameCounter += 1
        if backtrackFrameCounter >= activeConfig.backtrackAcceptanceFrames {
            backtrackFrameCounter = 0
            return candidate.progressAlongRoute
        }

        return previousCandidate.progressAlongRoute
    }

    private func confidence(from candidates: [MapMatchingCandidate]) -> Double {
        guard
            !candidates.isEmpty,
            let topScore = candidates.first?.score
        else { return 0 }

        let scores = candidates.compactMap { $0.score }
        guard !scores.isEmpty else { return 0 }

        let maxScore = scores.max() ?? topScore
        let expScores = scores.map { exp(($0) - maxScore) }
        let total = expScores.reduce(0, +)
        guard total > 0 else { return 0 }
        let topProb = expScores[0] / total
        let secondProb = expScores.count > 1 ? expScores[1] / total : 0
        return max(0, min(1, topProb - secondProb))
    }

    private func smooth(candidate: MapMatchingCandidate,
                        rawLocation: CLLocation,
                        expectedDisplacement: CLLocationDistance,
                        elapsed: TimeInterval) -> (coordinate: CLLocationCoordinate2D, heading: CLLocationDirection?, speed: CLLocationSpeed) {
        let candidateCoordinate = candidate.coordinate
        let smoothedCoordinate: CLLocationCoordinate2D
        if let previous = previousEnhanced?.coordinate {
            smoothedCoordinate = smoothCoordinate(from: previous,
                                                  to: candidateCoordinate,
                                                  maxStep: max(expectedDisplacement * 1.5, 5),
                                                  alpha: activeConfig.positionAlpha)
        } else {
            smoothedCoordinate = candidateCoordinate
        }

        let candidateHeading = candidate.heading ?? (rawLocation.course >= 0 ? rawLocation.course : nil)
        let smoothedHeading: CLLocationDirection?
        if let candidateHeading {
            smoothedHeading = smoothHeading(previous: previousEnhanced?.heading,
                                            newHeading: candidateHeading,
                                            alpha: activeConfig.headingAlpha)
        } else {
            smoothedHeading = previousEnhanced?.heading
        }

        let speed = deriveSpeed(from: rawLocation,
                                candidate: candidate,
                                elapsed: elapsed)

        return (smoothedCoordinate, smoothedHeading, speed)
    }

    private func smoothCoordinate(from start: CLLocationCoordinate2D,
                                  to target: CLLocationCoordinate2D,
                                  maxStep: CLLocationDistance,
                                  alpha: Double) -> CLLocationCoordinate2D {
        let startPoint = MKMapPoint(start)
        let targetPoint = MKMapPoint(target)
        let distance = startPoint.distance(to: targetPoint)
        guard distance > 0 else { return target }

        let limitingFactor = maxStep > 0 ? min(1, maxStep / distance) : 1
        let effectiveAlpha = max(0, min(1, alpha * limitingFactor))
        let newPoint = MKMapPoint(x: startPoint.x + (targetPoint.x - startPoint.x) * effectiveAlpha,
                                  y: startPoint.y + (targetPoint.y - startPoint.y) * effectiveAlpha)
        return newPoint.coordinate
    }

    private func smoothHeading(previous: CLLocationDirection?,
                               newHeading: CLLocationDirection,
                               alpha: Double) -> CLLocationDirection {
        guard let previous else { return newHeading }
        let prevRad = previous * .pi / 180
        let newRad = newHeading * .pi / 180
        let weightNew = max(0, min(1, alpha))
        let weightPrev = 1 - weightNew

        let x = weightPrev * cos(prevRad) + weightNew * cos(newRad)
        let y = weightPrev * sin(prevRad) + weightNew * sin(newRad)
        var result = atan2(y, x) * 180 / .pi
        if result < 0 { result += 360 }
        return result
    }

    private func deriveSpeed(from location: CLLocation,
                             candidate: MapMatchingCandidate,
                             elapsed: TimeInterval) -> CLLocationSpeed {
        if location.speed.isFinite, location.speed >= 0 {
            return location.speed
        }

        guard let previousCandidate else { return 0 }
        let delta = max(0, candidate.progressAlongRoute - previousCandidate.progressAlongRoute)
        let denominator = max(elapsed, 0.2)
        return delta / denominator
    }

    private func expectedTravelDistance(speed: CLLocationSpeed, elapsed: TimeInterval) -> CLLocationDistance {
        let clampedSpeed = clampSpeed(speed)
        let clampedElapsed = max(elapsed, 0.2)
        let expected = clampedSpeed * clampedElapsed
        let lower = clampedSpeed * 0.5
        let upper = clampedSpeed * 1.5
        return clamp(expected, lower: lower, upper: upper)
    }

    private func clampSpeed(_ speed: CLLocationSpeed) -> CLLocationSpeed {
        guard speed.isFinite, speed >= 0 else { return 0 }
        return min(speed, 55) // ≈ 200 km/h
    }

    private func clamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
        return max(lower, min(upper, value))
    }

    private func blendFactor(for elapsed: TimeInterval) -> Double {
        let duration = max(activeConfig.deadReckoningBlendDuration, 0.1)
        return max(0, min(1, elapsed / duration))
    }

    private func interpolateCoordinate(from start: CLLocationCoordinate2D,
                                       to target: CLLocationCoordinate2D,
                                       factor: Double) -> CLLocationCoordinate2D {
        guard factor > 0 else { return start }
        guard factor < 1 else { return target }
        let startPoint = MKMapPoint(start)
        let targetPoint = MKMapPoint(target)
        let newPoint = MKMapPoint(x: startPoint.x + (targetPoint.x - startPoint.x) * factor,
                                  y: startPoint.y + (targetPoint.y - startPoint.y) * factor)
        return newPoint.coordinate
    }

    private func shouldEnterDeadReckoning(for location: CLLocation,
                                          segments: [CorridorSegmentMetadata],
                                          elapsed: TimeInterval) -> Bool {
        guard previousEnhanced != nil else { return false }

        if segments.isEmpty {
            return true
        }

        if location.horizontalAccuracy > activeConfig.deadReckoningAccuracyThreshold {
            return true
        }

        if !location.speed.isFinite || location.speed < 0 {
            return true
        }

        if elapsed > activeConfig.deadReckoningGapThreshold {
            return true
        }

        return false
    }

    private func produceDeadReckonedLocation(from location: CLLocation,
                                             elapsed: TimeInterval) -> EnhancedLocation? {
        guard
            let storedEnhanced = previousEnhanced,
            let storedCandidate = previousCandidate
        else {
            return nil
        }

        let heading = storedEnhanced.heading ?? storedCandidate.heading ?? (location.course >= 0 ? location.course : nil)
        guard let heading else { return nil }

        let baseSpeed = location.speed.isFinite && location.speed >= 0
            ? location.speed
            : storedEnhanced.speed ?? 0
        let displacement = min(activeConfig.deadReckoningMaxDistance,
                               max(0, baseSpeed) * max(elapsed, 0.2))
        guard displacement > 0 else { return nil }

        let projectedCoordinate = offset(from: storedEnhanced.coordinate,
                                         heading: heading,
                                         distance: displacement)

        let candidate = MapMatchingCandidate(
            coordinate: projectedCoordinate,
            distanceFromRoute: storedCandidate.distanceFromRoute,
            progressAlongRoute: storedCandidate.progressAlongRoute + displacement,
            heading: heading,
            segmentIndex: storedCandidate.segmentIndex,
            stepIndex: storedCandidate.stepIndex,
            curvature: storedCandidate.curvature,
            distanceToNextManeuver: max(0, storedCandidate.distanceToNextManeuver - displacement),
            headingDifference: 0,
            isNearFork: storedCandidate.isNearFork,
            score: storedCandidate.score,
            emissionScore: storedCandidate.emissionScore,
            transitionScore: storedCandidate.transitionScore
        )

        let timestamp = location.timestamp
        let enhanced = EnhancedLocation(
            coordinate: projectedCoordinate,
            heading: heading,
            speed: baseSpeed,
            timestamp: timestamp,
            confidence: max(0, storedEnhanced.confidence - 0.1),
            candidate: candidate
        )

        deadReckoningState = DeadReckoningState(lastPrediction: enhanced,
                                               startedAt: timestamp,
                                               blendAnchor: nil,
                                               blendStartedAt: nil)
        previousCandidate = candidate
        previousEnhanced = enhanced

        return enhanced
    }

    private func offset(from coordinate: CLLocationCoordinate2D,
                        heading: CLLocationDirection,
                        distance: CLLocationDistance) -> CLLocationCoordinate2D {
        let headingRadians = heading * .pi / 180
        let earthRadius = 6_371_000.0
        let distanceRatio = distance / earthRadius

        let lat1 = coordinate.latitude.toRadians
        let lon1 = coordinate.longitude.toRadians

        let lat2 = asin(sin(lat1) * cos(distanceRatio) + cos(lat1) * sin(distanceRatio) * cos(headingRadians))
        let lon2 = lon1 + atan2(sin(headingRadians) * sin(distanceRatio) * cos(lat1),
                                cos(distanceRatio) - sin(lat1) * sin(lat2))

        return CLLocationCoordinate2D(latitude: lat2.toDegrees,
                                      longitude: lon2.toDegrees)
    }

    private func updateDiagnostics(with enhanced: EnhancedLocation,
                                   candidate: MapMatchingCandidate) {
        _ = candidate
        guard let previous = previousEnhanced else { return }
        let previousPoint = MKMapPoint(previous.coordinate)
        let currentPoint = MKMapPoint(enhanced.coordinate)
        let jitter = previousPoint.distance(to: currentPoint)
        diagnostics.jitter.addSample(jitter)
    }

    private struct DeadReckoningState {
        var lastPrediction: EnhancedLocation
        var startedAt: Date
        var blendAnchor: EnhancedLocation?
        var blendStartedAt: Date?
    }

    private struct Diagnostics {
        var jitter = RunningStatistics()
    }

    private struct RunningStatistics {
        private(set) var sumOfSquares: Double = 0
        private(set) var count: Int = 0

        mutating func addSample(_ value: Double) {
            sumOfSquares += value * value
            count += 1
        }

        var rms: Double {
            guard count > 0 else { return 0 }
            return sqrt(sumOfSquares / Double(count))
        }
    }
}

private extension CLLocationDegrees {
    var toRadians: Double { self * .pi / 180 }
    var toDegrees: Double { self * 180 / .pi }
}
