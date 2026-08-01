import Combine
import MapKit
import SwiftUI
import UIKit

enum RegionChangeCause {
    case initial
    case real
    case poi
    case journey
    case user
    case other
}

/// Describes the part of a map that remains useful after persistent chrome
/// covers its top or bottom edge. A destination is framed against this visible
/// area, rather than the full Map view, so its pin does not land underneath a
/// compact capsule.
struct MapCameraViewport {
    let size: CGSize
    let topInset: CGFloat
    let bottomInset: CGFloat

    func framed(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        guard size.width > 1, size.height > 1 else { return region }

        let height = size.height
        let top = min(max(0, topInset), height)
        let bottom = min(max(0, bottomInset), max(0, height - top))
        let centerOffset = (bottom - top) / (2 * height)
        guard abs(centerOffset) > .ulpOfOne else { return region }

        let halfLatitude = region.span.latitudeDelta / 2
        let north = CLLocationCoordinate2D(
            latitude: min(85, region.center.latitude + halfLatitude),
            longitude: region.center.longitude
        )
        let south = CLLocationCoordinate2D(
            latitude: max(-85, region.center.latitude - halfLatitude),
            longitude: region.center.longitude
        )
        let northPoint = MKMapPoint(north)
        let southPoint = MKMapPoint(south)
        let regionHeight = abs(southPoint.y - northPoint.y)
        let westPoint = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: region.center.latitude,
                longitude: region.center.longitude - region.span.longitudeDelta / 2
            )
        )
        let eastPoint = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: region.center.latitude,
                longitude: region.center.longitude + region.span.longitudeDelta / 2
            )
        )
        let regionWidth = abs(eastPoint.x - westPoint.x)
        guard regionHeight.isFinite, regionWidth.isFinite,
              regionHeight > 0, regionWidth > 0 else {
            return region
        }

        // A MapKit region is fitted to the viewport's aspect ratio. On a
        // portrait phone its actual vertical map span is normally wider than
        // the requested latitude span, because longitude sets the scale.
        // Offset against that visible span, otherwise the correction is only
        // half as large as the card actually requires.
        let mapPointsPerScreenPoint = max(regionHeight / height, regionWidth / size.width)
        let visibleMapHeight = mapPointsPerScreenPoint * height

        let center = MKMapPoint(region.center)
        let shiftedY = min(
            max(MKMapRect.world.minY, center.y + visibleMapHeight * centerOffset),
            MKMapRect.world.maxY
        )
        return MKCoordinateRegion(
            center: MKMapPoint(x: center.x, y: shiftedY).coordinate,
            span: region.span
        )
    }
}

final class MapFlightController: ObservableObject {
    private var activeTransitionID: UUID?

    func cancelActiveTransition() {
        activeTransitionID = nil
    }

    func handleRegionChange(
        currentRegion: MKCoordinateRegion?,
        targetRegion: MKCoordinateRegion,
        cause: RegionChangeCause,
        viewport: MapCameraViewport? = nil,
        cameraPosition: Binding<MapCameraPosition>,
        onRegionUpdate: @escaping (MKCoordinateRegion) -> Void
    ) {
        if activeTransitionID != nil {
            activeTransitionID = nil
        }

        let clampedTarget = cityClamp(targetRegion)
        guard let existingRegion = currentRegion else {
            let framedTarget = viewport?.framed(clampedTarget) ?? clampedTarget
            withAnimation(smoothAnimation(duration: 0.5)) {
                cameraPosition.wrappedValue = .region(framedTarget)
            }
            onRegionUpdate(framedTarget)
            return
        }

        let travelDistance = existingRegion.center.distance(to: targetRegion.center)
        let currentSpan = existingRegion.dominantSpanMeters
        let targetSpan = targetRegion.dominantSpanMeters

        if existingRegion.contains(targetRegion.center, insetFraction: 0.92) &&
            targetSpan <= currentSpan * 1.15 {
            let preserved = MKCoordinateRegion(center: targetRegion.center, span: existingRegion.span)
            let framedPreserved = viewport?.framed(preserved) ?? preserved
            let duration = min(0.25 + (travelDistance / 180_000.0), 0.45)
            withAnimation(smoothAnimation(duration: duration)) {
                cameraPosition.wrappedValue = .region(framedPreserved)
            }
            onRegionUpdate(framedPreserved)
            return
        }

        if cause != .initial,
           cause != .other,
           travelDistance < currentSpan * 2,
           targetSpan > currentSpan * 1.3 {
            // Keep tight zoom for nearby hops instead of zooming out to the target span.
            let preserved = MKCoordinateRegion(center: targetRegion.center, span: existingRegion.span)
            let framedPreserved = viewport?.framed(preserved) ?? preserved
            let duration = min(0.25 + (travelDistance / 180_000.0), 0.45)
            withAnimation(smoothAnimation(duration: duration)) {
                cameraPosition.wrappedValue = .region(framedPreserved)
            }
            onRegionUpdate(framedPreserved)
            return
        }

        if UIAccessibility.isReduceMotionEnabled {
            activeTransitionID = nil
            let d = min(0.30 + (travelDistance / 150_000.0), 0.45)
            let framedTarget = viewport?.framed(clampedTarget) ?? clampedTarget
            withAnimation(smoothAnimation(duration: d)) {
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
    ) -> TransitionPlan {
        switch cause {
        case .initial, .other:
            return .direct
        case .user, .poi, .real, .journey:
            return stagedPlan(
                for: travelDistance,
                baseSpan: max(current.dominantSpanMeters, target.dominantSpanMeters)
            )
        }
    }

    private func stagedPlan(
        for travelDistance: CLLocationDistance,
        baseSpan: CLLocationDistance
    ) -> TransitionPlan {
        if travelDistance > 280_000 {
            let zoomDistance = clamp(travelDistance * 8, lower: 1_800_000, upper: 40_000_000)
            return .staged(zoomDistance: zoomDistance, tempo: .cinematic)
        } else if travelDistance > 120_000 {
            let zoomDistance = clamp(max(travelDistance * 1.7, baseSpan * 4.2), lower: 320_000, upper: 1_600_000)
            return .staged(zoomDistance: zoomDistance, tempo: .cinematic)
        } else if travelDistance > 55_000 {
            let zoomDistance = clamp(max(travelDistance * 1.45, baseSpan * 2.8), lower: 85_000, upper: 220_000)
            return .staged(zoomDistance: zoomDistance, tempo: .subtle)
        } else if travelDistance > 12_000 {
            let zoomDistance = clamp(max(travelDistance * 1.30, baseSpan * 2.1), lower: 40_000, upper: 120_000)
            return .staged(zoomDistance: zoomDistance, tempo: .subtle)
        } else {
            return .direct
        }
    }

    private func apply(
        plan: TransitionPlan,
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
            withAnimation(smoothAnimation(duration: duration)) {
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
        tempo: TransitionTempo,
        viewport: MapCameraViewport?,
        cameraPosition: Binding<MapCameraPosition>,
        onRegionUpdate: @escaping (MKCoordinateRegion) -> Void
    ) {
        let id = UUID()
        activeTransitionID = id
        let durations = tempo.durations
        let liftFraction = tempo == .cinematic ? 0.38 : 0.26
        let liftCenter = current.center.interpolated(to: target.center, fraction: liftFraction)
        let liftPitch: CGFloat = tempo == .cinematic ? 36 : 0
        let cruisePitch: CGFloat = tempo == .cinematic ? 36 : 0

        withAnimation(smoothAnimation(duration: durations.zoomOut)) {
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
            withAnimation(smoothAnimation(duration: durations.travel)) {
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
        withAnimation(smoothAnimation(duration: duration)) {
            cameraPosition.wrappedValue = .region(framedTarget)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.activeTransitionID == id else { return }
            onRegionUpdate(framedTarget)
            self.activeTransitionID = nil
        }
    }

    private func cityClamp(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        let meters = clamp(region.dominantSpanMeters, lower: 20_000, upper: 60_000)
        return MKCoordinateRegion(center: region.center, latitudinalMeters: meters, longitudinalMeters: meters)
    }
}

private enum TransitionPlan {
    case direct
    case staged(zoomDistance: CLLocationDistance, tempo: TransitionTempo)
}

private enum TransitionTempo {
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

private func smoothAnimation(duration: Double) -> Animation {
    Animation.timingCurve(0.25, 0.1, 0.25, 1.0, duration: duration)
}

private func clamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
    max(lower, min(value, upper))
}

extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        let origin = CLLocation(latitude: latitude, longitude: longitude)
        let target = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return origin.distance(from: target)
    }

    func interpolated(to other: CLLocationCoordinate2D, fraction: Double) -> CLLocationCoordinate2D {
        let clampedFraction = max(0, min(1, fraction))
        guard clampedFraction > 0 else { return self }
        guard clampedFraction < 1 else { return other }

        let lat1 = latitude * .pi / 180
        let lon1 = longitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let lon2 = other.longitude * .pi / 180

        let sinLat = sin((lat2 - lat1) / 2)
        let sinLon = sin((lon2 - lon1) / 2)
        let a = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        let angularDistance = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))

        if angularDistance.isZero {
            return other
        }

        let sinDistance = sin(angularDistance)
        let weightStart = sin((1 - clampedFraction) * angularDistance) / sinDistance
        let weightEnd = sin(clampedFraction * angularDistance) / sinDistance

        let x = weightStart * cos(lat1) * cos(lon1) + weightEnd * cos(lat2) * cos(lon2)
        let y = weightStart * cos(lat1) * sin(lon1) + weightEnd * cos(lat2) * sin(lon2)
        let z = weightStart * sin(lat1) + weightEnd * sin(lat2)

        let interpolatedLatitude = atan2(z, sqrt(x * x + y * y))
        let interpolatedLongitude = atan2(y, x)

        return CLLocationCoordinate2D(
            latitude: interpolatedLatitude * 180 / .pi,
            longitude: interpolatedLongitude * 180 / .pi
        )
    }
}

private extension MKCoordinateRegion {
    var dominantSpanMeters: CLLocationDistance {
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

    func contains(_ coordinate: CLLocationCoordinate2D, insetFraction: Double = 1.0) -> Bool {
        let clampedFraction = max(0.0, min(1.0, insetFraction))
        let latRadius = span.latitudeDelta * 0.5 * clampedFraction
        let lonRadius = span.longitudeDelta * 0.5 * clampedFraction

        let latDelta = coordinate.latitude - center.latitude
        let lonDelta = coordinate.longitude - center.longitude

        return abs(latDelta) <= latRadius && abs(lonDelta) <= lonRadius
    }
}
