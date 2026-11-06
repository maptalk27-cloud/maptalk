import Combine
import MapKit
import SwiftUI
import UIKit

/// MyMap's native camera path, restored from checkpoint a4836f4.
/// Keep this independent of MapTalk's story-flight tuning: MyMap retains
/// its original timing, zoom shortcuts and camera binding behavior.
final class MyMapFlightController: ObservableObject {
    private var activeTransitionID: UUID?
    private var stagedLandingRegion: MKCoordinateRegion?

    /// Highlight navigation saves the destination during a staged flight,
    /// but uses the visible map again once that flight finishes or is cancelled.
    var pendingLandingRegion: MKCoordinateRegion? {
        activeTransitionID == nil ? nil : stagedLandingRegion
    }

    func cancelActiveTransition() {
        activeTransitionID = nil
        stagedLandingRegion = nil
    }

    func handleRegionChange(
        currentRegion: MKCoordinateRegion?,
        targetRegion: MKCoordinateRegion,
        cause: RegionChangeCause,
        viewport: MapCameraViewport? = nil,
        cameraPosition: Binding<MapCameraPosition>,
        onRegionUpdate: @escaping (MKCoordinateRegion) -> Void
    ) {
        let wasTransitioning = activeTransitionID != nil
        activeTransitionID = nil

        cancelActiveTransition()
        let clampedTarget = cityClamp(targetRegion)
        guard let existingRegion = currentRegion else {
            let framedTarget = viewport?.framed(clampedTarget) ?? clampedTarget
            withAnimation(myMapSmoothAnimation(duration: 0.5)) {
                cameraPosition.wrappedValue = .region(framedTarget)
            }
            onRegionUpdate(framedTarget)
            return
        }

        let travelDistance = existingRegion.center.distance(to: targetRegion.center)
        let currentSpan = existingRegion.myMapDominantSpanMeters
        let targetSpan = targetRegion.myMapDominantSpanMeters

        if !wasTransitioning &&
            existingRegion.myMapContains(targetRegion.center, insetFraction: 0.92) &&
            targetSpan <= currentSpan * 1.15 {
            let preserved = MKCoordinateRegion(center: targetRegion.center, span: existingRegion.span)
            let framedPreserved = viewport?.framed(preserved) ?? preserved
            let duration = min(0.25 + (travelDistance / 180_000.0), 0.45)
            withAnimation(myMapSmoothAnimation(duration: duration)) {
                cameraPosition.wrappedValue = .region(framedPreserved)
            }
            onRegionUpdate(framedPreserved)
            return
        }

        if !wasTransitioning,
           cause != .initial,
           cause != .other,
           travelDistance < currentSpan * 2,
           targetSpan > currentSpan * 1.3 {
            // Keep tight zoom for nearby hops instead of zooming out to the target span.
            let preserved = MKCoordinateRegion(center: targetRegion.center, span: existingRegion.span)
            let framedPreserved = viewport?.framed(preserved) ?? preserved
            let duration = min(0.25 + (travelDistance / 180_000.0), 0.45)
            withAnimation(myMapSmoothAnimation(duration: duration)) {
                cameraPosition.wrappedValue = .region(framedPreserved)
            }
            onRegionUpdate(framedPreserved)
            return
        }

        if UIAccessibility.isReduceMotionEnabled {
            activeTransitionID = nil
            let d = min(0.30 + (travelDistance / 150_000.0), 0.45)
            let framedTarget = viewport?.framed(clampedTarget) ?? clampedTarget
            withAnimation(myMapSmoothAnimation(duration: d)) {
                cameraPosition.wrappedValue = .region(framedTarget)
            }
            onRegionUpdate(framedTarget)
            return
        }

        let plan = transitionPlan(
            for: travelDistance,
            cause: cause,
            current: existingRegion,
            target: targetRegion
        )
        apply(
            plan: plan,
            current: existingRegion,
            target: targetRegion,
            travelDistance: travelDistance,
            viewport: viewport,
            cameraPosition: cameraPosition,
            onRegionUpdate: onRegionUpdate
        )
    }

    private func transitionPlan(
        for travelDistance: CLLocationDistance,
        cause: RegionChangeCause,
        current: MKCoordinateRegion,
        target: MKCoordinateRegion
    ) -> MyMapTransitionPlan {
        switch cause {
        case .initial, .other:
            return .direct
        case .user, .poi, .real, .journey:
            return stagedPlan(
                for: travelDistance,
                baseSpan: max(current.myMapDominantSpanMeters, target.myMapDominantSpanMeters)
            )
        }
    }

    private func stagedPlan(
        for travelDistance: CLLocationDistance,
        baseSpan: CLLocationDistance
    ) -> MyMapTransitionPlan {
        if travelDistance > 280_000 {
            let zoomDistance = myMapClamp(travelDistance * 8, lower: 1_800_000, upper: 40_000_000)
            return .staged(zoomDistance: zoomDistance, tempo: .cinematic)
        } else if travelDistance > 120_000 {
            let zoomDistance = myMapClamp(max(travelDistance * 1.7, baseSpan * 4.2), lower: 320_000, upper: 1_600_000)
            return .staged(zoomDistance: zoomDistance, tempo: .cinematic)
        } else if travelDistance > 55_000 {
            let zoomDistance = myMapClamp(max(travelDistance * 1.45, baseSpan * 2.8), lower: 85_000, upper: 220_000)
            return .staged(zoomDistance: zoomDistance, tempo: .subtle)
        } else if travelDistance > 12_000 {
            let zoomDistance = myMapClamp(max(travelDistance * 1.30, baseSpan * 2.1), lower: 40_000, upper: 120_000)
            return .staged(zoomDistance: zoomDistance, tempo: .subtle)
        } else {
            return .direct
        }
    }

    private func apply(
        plan: MyMapTransitionPlan,
        current: MKCoordinateRegion,
        target: MKCoordinateRegion,
        travelDistance: CLLocationDistance,
        viewport: MapCameraViewport?,
        cameraPosition: Binding<MapCameraPosition>,
        onRegionUpdate: @escaping (MKCoordinateRegion) -> Void
    ) {
        switch plan {
        case .direct:
            activeTransitionID = nil
            let duration = min(0.35 + (travelDistance / 120_000.0), 0.55)
            let clamped = cityClamp(target)
            let framedTarget = viewport?.framed(clamped) ?? clamped
            withAnimation(myMapSmoothAnimation(duration: duration)) {
                cameraPosition.wrappedValue = .region(framedTarget)
            }
            onRegionUpdate(framedTarget)

        case let .staged(zoomDistance, tempo):
            runStagedTransition(
                from: current,
                to: target,
                zoomDistance: zoomDistance,
                tempo: tempo,
                viewport: viewport,
                cameraPosition: cameraPosition,
                onRegionUpdate: onRegionUpdate
            )
        }
    }

    private func runStagedTransition(
        from current: MKCoordinateRegion,
        to target: MKCoordinateRegion,
        zoomDistance: CLLocationDistance,
        tempo: MyMapTransitionTempo,
        viewport: MapCameraViewport?,
        cameraPosition: Binding<MapCameraPosition>,
        onRegionUpdate: @escaping (MKCoordinateRegion) -> Void
    ) {
        let id = UUID()
        activeTransitionID = id
        let landing = cityClamp(target)
        stagedLandingRegion = viewport?.framed(landing) ?? landing
        let durations = tempo.durations
        let liftFraction = tempo == .cinematic ? 0.38 : 0.26
        let liftCenter = current.center.interpolated(to: target.center, fraction: liftFraction)
        let liftPitch: CGFloat = tempo == .cinematic ? 36 : 0
        let cruisePitch: CGFloat = tempo == .cinematic ? 36 : 0

        withAnimation(myMapSmoothAnimation(duration: durations.zoomOut)) {
            cameraPosition.wrappedValue = .camera(
                MapCamera(
                    centerCoordinate: liftCenter,
                    distance: zoomDistance,
                    heading: 0,
                    pitch: liftPitch
                )
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + durations.zoomOut) { [weak self] in
            guard let self, self.activeTransitionID == id else { return }
            withAnimation(myMapSmoothAnimation(duration: durations.travel)) {
                cameraPosition.wrappedValue = .camera(
                    MapCamera(
                        centerCoordinate: target.center,
                        distance: zoomDistance,
                        heading: 0,
                        pitch: cruisePitch
                    )
                )
            }
            self.scheduleDive(
                after: durations.travel,
                id: id,
                target: target,
                durations: durations,
                viewport: viewport,
                cameraPosition: cameraPosition,
                onRegionUpdate: onRegionUpdate
            )
        }
    }

    private func scheduleDive(
        after cruiseDuration: Double,
        id: UUID,
        target: MKCoordinateRegion,
        durations: (zoomOut: Double, travel: Double, prefetchHold: Double, zoomIn: Double),
        viewport: MapCameraViewport?,
        cameraPosition: Binding<MapCameraPosition>,
        onRegionUpdate: @escaping (MKCoordinateRegion) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + cruiseDuration) { [weak self] in
            guard let self, self.activeTransitionID == id else { return }
            self.completeDive(
                to: target,
                with: durations.zoomIn,
                transitionID: id,
                viewport: viewport,
                cameraPosition: cameraPosition,
                onRegionUpdate: onRegionUpdate
            )
        }
    }

    private func completeDive(
        to target: MKCoordinateRegion,
        with duration: Double,
        transitionID id: UUID,
        viewport: MapCameraViewport?,
        cameraPosition: Binding<MapCameraPosition>,
        onRegionUpdate: @escaping (MKCoordinateRegion) -> Void
    ) {
        let clamped = cityClamp(target)
        let framedTarget = viewport?.framed(clamped) ?? clamped
        withAnimation(myMapSmoothAnimation(duration: duration)) {
            cameraPosition.wrappedValue = .region(framedTarget)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.activeTransitionID == id else { return }
            onRegionUpdate(framedTarget)
            self.activeTransitionID = nil
            self.stagedLandingRegion = nil
        }
    }

    private func cityClamp(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        let meters = myMapClamp(region.myMapDominantSpanMeters, lower: 20_000, upper: 60_000)
        return MKCoordinateRegion(center: region.center, latitudinalMeters: meters, longitudinalMeters: meters)
    }
}

private enum MyMapTransitionPlan {
    case direct
    case staged(zoomDistance: CLLocationDistance, tempo: MyMapTransitionTempo)
}

private enum MyMapTransitionTempo {
    case subtle
    case cinematic

    var durations: (zoomOut: Double, travel: Double, prefetchHold: Double, zoomIn: Double) {
        switch self {
        case .subtle:
            return (0.2, 0.36, 0.08, 0.28)
        case .cinematic:
            return (1.5, 1.5, 0.02, 0.2)
        }
    }
}

private func myMapSmoothAnimation(duration: Double) -> Animation {
    Animation.timingCurve(0.25, 0.1, 0.25, 1.0, duration: duration)
}

private func myMapClamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
    max(lower, min(value, upper))
}

private extension MKCoordinateRegion {
    var myMapDominantSpanMeters: CLLocationDistance {
        let halfLatitude = span.latitudeDelta / 2
        let halfLongitude = span.longitudeDelta / 2

        let north = MKMapPoint(CLLocationCoordinate2D(latitude: center.latitude + halfLatitude, longitude: center.longitude))
        let south = MKMapPoint(CLLocationCoordinate2D(latitude: center.latitude - halfLatitude, longitude: center.longitude))
        let east = MKMapPoint(CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude + halfLongitude))
        let west = MKMapPoint(CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude - halfLongitude))

        let vertical = north.distance(to: south)
        let horizontal = east.distance(to: west)
        return max(vertical, horizontal)
    }

    func myMapContains(_ coordinate: CLLocationCoordinate2D, insetFraction: Double = 1.0) -> Bool {
        let clampedFraction = max(0.0, min(1.0, insetFraction))
        let latRadius = span.latitudeDelta * 0.5 * clampedFraction
        let lonRadius = span.longitudeDelta * 0.5 * clampedFraction

        let latDelta = coordinate.latitude - center.latitude
        let lonDelta = coordinate.longitude - center.longitude

        return abs(latDelta) <= latRadius && abs(lonDelta) <= lonRadius
    }
}
