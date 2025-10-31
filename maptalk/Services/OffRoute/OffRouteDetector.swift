import Combine
import Foundation
import MapKit

enum OffRouteDetectorMode {
    case city
    case highway
}

/// Determines on-route versus off-route status using snapped positions and heading deviation.
protocol OffRouteDetectorType: AnyObject {
    /// Emits transition events whenever the on/off-route classification changes.
    var events: AnyPublisher<OffRouteEvent, Never> { get }

    /// Updates tolerances or cached route geometry when a new route is selected.
    func update(route: MKRoute?)

    /// Adjusts thresholds based on the active matcher preset.
    func update(mode: OffRouteDetectorMode)

    /// Evaluates the latest enhanced location to detect potential off-route conditions.
    func ingest(enhancedLocation: EnhancedLocation)

    /// Resets internal hysteresis and time-based thresholds.
    func reset()
}

final class OffRouteDetector: OffRouteDetectorType {
    private struct Thresholds {
        var distance: CLLocationDistance
        var heading: CLLocationDirection
        var enterFrames: Int
        var exitFrames: Int
    }

    private let subject = PassthroughSubject<OffRouteEvent, Never>()
    private var route: MKRoute?
    private var currentMode: OffRouteDetectorMode = .city
    private var consecutiveOffRoute = 0
    private var consecutiveOnRoute = 0
    private var isOffRoute = false

    var events: AnyPublisher<OffRouteEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    func update(route: MKRoute?) {
        self.route = route
        reset()
    }

    func update(mode: OffRouteDetectorMode) {
        currentMode = mode
    }

    func ingest(enhancedLocation: EnhancedLocation) {
        let candidate = enhancedLocation.candidate
        let thresholds = thresholdsForCurrentMode(nearFork: candidate.isNearFork)

        let lateralDistance = candidate.distanceFromRoute
        let headingDeviation = candidate.headingDifference
        let confidence = enhancedLocation.confidence

        let distanceExceeded = lateralDistance > thresholds.distance
        let headingExceeded = headingDeviation > thresholds.heading

        let shouldFlagOffRoute: Bool
        if confidence < 0.2 {
            shouldFlagOffRoute = distanceExceeded && headingExceeded
        } else {
            shouldFlagOffRoute = distanceExceeded || (headingExceeded && lateralDistance > thresholds.distance * 0.6)
        }

        if shouldFlagOffRoute {
            consecutiveOffRoute += 1
            consecutiveOnRoute = 0
        } else {
            consecutiveOnRoute += 1
            consecutiveOffRoute = 0
        }

        if !isOffRoute, consecutiveOffRoute >= thresholds.enterFrames {
            isOffRoute = true
            emitEvent(isOffRoute: true,
                      lateral: lateralDistance,
                      heading: headingDeviation,
                      timestamp: enhancedLocation.timestamp)
        } else if isOffRoute, consecutiveOnRoute >= thresholds.exitFrames,
                  lateralDistance < thresholds.distance * 0.8 {
            isOffRoute = false
            emitEvent(isOffRoute: false,
                      lateral: lateralDistance,
                      heading: headingDeviation,
                      timestamp: enhancedLocation.timestamp)
        }
    }

    func reset() {
        consecutiveOffRoute = 0
        consecutiveOnRoute = 0
        isOffRoute = false
    }

    private func thresholdsForCurrentMode(nearFork: Bool) -> Thresholds {
        let base: Thresholds
        switch currentMode {
        case .city:
            base = Thresholds(distance: 28, heading: 55, enterFrames: 3, exitFrames: 5)
        case .highway:
            base = Thresholds(distance: 48, heading: 45, enterFrames: 3, exitFrames: 5)
        }

        guard nearFork else { return base }

        return Thresholds(distance: base.distance * 1.3,
                          heading: base.heading * 1.2,
                          enterFrames: base.enterFrames + 1,
                          exitFrames: base.exitFrames)
    }

    private func emitEvent(isOffRoute: Bool,
                           lateral: CLLocationDistance,
                           heading: CLLocationDirection,
                           timestamp: Date) {
        let event = OffRouteEvent(isOffRoute: isOffRoute,
                                  timestamp: timestamp,
                                  lateralDeviation: lateral,
                                  headingDeviation: heading)
        subject.send(event)
    }
}
