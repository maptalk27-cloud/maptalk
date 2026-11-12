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

/// App camera commands invalidate the view. MapKit's own binding echoes do
/// not: they already describe native state, including an animation's future
/// endpoint, and must not be issued back as another camera command.
final class MapCameraPositionStore: ObservableObject {
    private(set) var position: MapCameraPosition

    init(_ position: MapCameraPosition = .automatic) { self.position = position }

    var commandBinding: Binding<MapCameraPosition> {
        Binding(get: { self.position }, set: { self.setCommand($0) })
    }

    func setCommand(_ position: MapCameraPosition) {
        objectWillChange.send()
        self.position = position
    }

    func observeNativePosition(_ position: MapCameraPosition) {
        self.position = position
    }
}

final class MapFlightController: ObservableObject {
    private var activeTransitionID: UUID?
    private var visibleRegion: MKCoordinateRegion?
    private var visibleCamera: MapCamera?
    private var cameraObservationRevision: UInt64 = 0
    private var pendingDive: PendingDive?
    private var hasIssuedLanding = false
    private(set) var hasUnsettledNativeFlight = false
    private var transitionEndsAt: CFTimeInterval = 0
    private var stagedLandingRegion: MKCoordinateRegion?
    private var neighborhoodSource: [CLLocationCoordinate2D]?
    private var cachedNeighborhood: MapBrowsingNeighborhood?
    var isTransitionInProgress: Bool {
        activeTransitionID != nil && (pendingDive != nil || CACurrentMediaTime() < transitionEndsAt - 0.08)
    }

    private struct PendingDive {
        let id: UUID
        let transitionID: UUID
        let cruiseCamera: MapCamera
        let departure: CLLocationCoordinate2D
        let centerTolerance: CLLocationDistance
        let earliestStart: CFTimeInterval
        let observationRevision: UInt64
        let begin: (_ recoveringFromAdjustedOverview: Bool) -> Void
        var isScheduled = false
        var nativeEnded = false
    }

    /// A child opened during flight must return to the selected post, not a
    /// stale departure captured before MapKit's settled-camera callback.
    /// Once settled, callers keep using the user's exact camera snapshot.
    var pendingLandingRegion: MKCoordinateRegion? {
        stagedLandingRegion
    }

    // Kept off published/view state: observing the live camera must not rebuild
    // the map's cards and annotations at display refresh frequency.
    func observeCamera(region: MKCoordinateRegion, camera: MapCamera? = nil) {
        visibleRegion = region
        if let camera {
            if let previous = visibleCamera,
               abs(previous.centerCoordinate.latitude - camera.centerCoordinate.latitude) > 0.000_000_1
                || abs(previous.centerCoordinate.longitude - camera.centerCoordinate.longitude) > 0.000_000_1
                || abs(previous.distance - camera.distance) > 1 {
                pendingDive?.nativeEnded = false
            }
            visibleCamera = camera
            cameraObservationRevision &+= 1
        }
        beginDiveIfReady()
    }

    func observeCameraEnd() {
        if pendingDive != nil {
            pendingDive?.nativeEnded = true
            beginDiveIfReady()
        }
        // A very short return can finish natively before its requested timer.
        // Remember that real completion; otherwise the timer leaves the flight
        // "unsettled" forever waiting for an onEnd that already happened.
        if hasIssuedLanding, let target = stagedLandingRegion,
           let visibleRegion, visibleRegion.matchesFittedLanding(target) {
            transitionEndsAt = 0
            hasUnsettledNativeFlight = false
            stagedLandingRegion = nil
            hasIssuedLanding = false
            return
        }
        // MapKit's native region animation can outlive the requested duration.
        // Keep destination/zoom protection until its real end, not our timer.
        if !hasIssuedLanding && !isTransitionInProgress {
            hasUnsettledNativeFlight = false
            stagedLandingRegion = nil
        }
    }

    func cancelActiveTransition() {
        activeTransitionID = nil
        pendingDive = nil
        hasIssuedLanding = false
        stagedLandingRegion = nil
        transitionEndsAt = 0
        hasUnsettledNativeFlight = false
    }

    private func finishScheduledStages() {
        activeTransitionID = nil
        transitionEndsAt = 0
        if !hasUnsettledNativeFlight { stagedLandingRegion = nil }
    }

    /// Only browsing opts into neighborhood framing. Ordinary map/search and
    /// isolated stops keep their existing target and flight behavior.
    func neighborhoodRegion(for region: MKCoordinateRegion,
                            coordinates: [CLLocationCoordinate2D]?) -> MKCoordinateRegion? {
        guard let coordinates else {
            neighborhoodSource = nil
            cachedNeighborhood = nil
            return nil
        }
        // MyMap may contain hundreds of records. Adjacent swipes reuse the
        // same patch; only changed scopes or leaving that patch regroup stops.
        let sameSource = neighborhoodSource?.elementsEqual(coordinates, by: {
            $0.latitude == $1.latitude && $0.longitude == $1.longitude
        }) == true
        if !sameSource || cachedNeighborhood?.contains(region.center) != true {
            neighborhoodSource = coordinates
            cachedNeighborhood = MapBrowsingNeighborhood.resolve(around: region.center,
                                                                  coordinates: coordinates)
        }
        guard let neighborhood = cachedNeighborhood else { return nil }
        return MKCoordinateRegion(center: region.center,
            latitudinalMeters: neighborhood.span, longitudinalMeters: neighborhood.span)
    }

    func handleRegionChange(
        currentRegion: MKCoordinateRegion?,
        targetRegion: MKCoordinateRegion,
        cause: RegionChangeCause,
        viewport: MapCameraViewport? = nil,
        browsingCoordinates: [CLLocationCoordinate2D]? = nil,
        cameraPosition: Binding<MapCameraPosition>,
        onRegionUpdate: @escaping (MKCoordinateRegion) -> Void
    ) {
        // A camera callback during lift/cruise contains the flight's temporary
        // wide zoom, not a zoom chosen by the user. A replacement flight must
        // land at its destination instead of preserving that intermediate span.
        let wasTransitioning = activeTransitionID != nil || hasUnsettledNativeFlight
        cancelActiveTransition()
        let localTarget = neighborhoodRegion(for: targetRegion, coordinates: browsingCoordinates)
        let requestedTarget = localTarget ?? targetRegion
        let clampedTarget = localTarget ?? cityClamp(targetRegion)
        guard let existingRegion = visibleRegion ?? currentRegion else {
            let framedTarget = viewport?.framed(clampedTarget) ?? clampedTarget
            moveDirectly(to: framedTarget, duration: 0.5,
                cameraPosition: cameraPosition, onRegionUpdate: onRegionUpdate)
            return
        }

        let travelDistance = existingRegion.center.distance(to: targetRegion.center)
        let currentSpan = existingRegion.dominantSpanMeters
        let targetSpan = requestedTarget.dominantSpanMeters
        // Sample the observed screen scale once, before the flight widens it.
        // Only stretch the existing timeline; keep native paths/easing intact.
        let durationScale = cause != .initial && cause != .other && !UIAccessibility.isReduceMotionEnabled
            ? MapFlightPacing.durationScale(travelDistance: travelDistance, visibleSpan: currentSpan)
            : 1
        let plan = transitionPlan(
            for: travelDistance,
            cause: cause,
            current: wasTransitioning ? cityClamp(existingRegion) : existingRegion,
            // Dense-stop framing changes only the landing scale. Do not let
            // it rewrite the legacy flight's overview height or travel tempo.
            target: targetRegion
        )
        // Preserve a user's closer view, never the broad city view that made
        // nearby stops indistinguishable. One neighborhood has one target scale.
        let canPreserveZoom = localTarget == nil || currentSpan <= targetSpan * 1.15

        // Screen containment is only a shortcut for a local/direct move.
        // A broad viewport can contain both Honolulu and Lanai; it must not
        // override their distance-based flight or preserve an island-wide zoom.
        if case .direct = plan, !wasTransitioning && canPreserveZoom &&
            existingRegion.contains(targetRegion.center, insetFraction: 0.92) &&
            targetSpan <= currentSpan * 1.15 {
            let preserved = MKCoordinateRegion(center: targetRegion.center, span: existingRegion.span)
            let framedPreserved = viewport?.framed(preserved) ?? preserved
            let duration = min(0.25 + (travelDistance / 180_000.0), 0.45) * durationScale
            moveDirectly(to: framedPreserved, duration: duration,
                cameraPosition: cameraPosition, onRegionUpdate: onRegionUpdate)
            return
        }

        if case .direct = plan, !wasTransitioning, canPreserveZoom,
           cause != .initial,
           cause != .other,
           travelDistance < currentSpan * 2,
           targetSpan > currentSpan * 1.3 {
            // Keep tight zoom for nearby hops instead of zooming out to the target span.
            let preserved = MKCoordinateRegion(center: targetRegion.center, span: existingRegion.span)
            let framedPreserved = viewport?.framed(preserved) ?? preserved
            let duration = min(0.25 + (travelDistance / 180_000.0), 0.45) * durationScale
            moveDirectly(to: framedPreserved, duration: duration,
                cameraPosition: cameraPosition, onRegionUpdate: onRegionUpdate)
            return
        }

        if UIAccessibility.isReduceMotionEnabled {
            let d = min(0.30 + (travelDistance / 150_000.0), 0.45)
            let framedTarget = viewport?.framed(clampedTarget) ?? clampedTarget
            moveDirectly(to: framedTarget, duration: d,
                cameraPosition: cameraPosition, onRegionUpdate: onRegionUpdate)
            return
        }

        apply(
            plan: plan,
            current: existingRegion,
            target: targetRegion,
            landing: clampedTarget,
            travelDistance: travelDistance,
            durationScale: durationScale,
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
        landing: MKCoordinateRegion,
        travelDistance: CLLocationDistance,
        durationScale: Double,
        viewport: MapCameraViewport?,
        cameraPosition: Binding<MapCameraPosition>,
        onRegionUpdate: @escaping (MKCoordinateRegion) -> Void
    ) {
        switch plan {
        case .direct:
            let duration = min(0.35 + (travelDistance / 120_000.0), 0.55) * durationScale
            let framedTarget = viewport?.framed(landing) ?? landing
            moveDirectly(to: framedTarget, duration: duration,
                cameraPosition: cameraPosition, onRegionUpdate: onRegionUpdate)

        case let .staged(zoomDistance, tempo):
            runStagedTransition(
                from: current,
                to: target,
                landing: landing,
                zoomDistance: zoomDistance,
                tempo: tempo,
                durationScale: durationScale,
                viewport: viewport,
                cameraPosition: cameraPosition,
                onRegionUpdate: onRegionUpdate
            )
        }
    }

    private func moveDirectly(to target: MKCoordinateRegion, duration: Double,
                              cameraPosition: Binding<MapCameraPosition>,
                              onRegionUpdate: @escaping (MKCoordinateRegion) -> Void) {
        hasUnsettledNativeFlight = true
        hasIssuedLanding = true
        let id = UUID()
        activeTransitionID = id
        stagedLandingRegion = target
        transitionEndsAt = CACurrentMediaTime() + duration
        withAnimation(smoothAnimation(duration: duration)) {
            cameraPosition.wrappedValue = .region(target)
        }
        onRegionUpdate(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.activeTransitionID == id else { return }
            self.finishScheduledStages()
        }
    }

    private func runStagedTransition(
        from current: MKCoordinateRegion,
        to target: MKCoordinateRegion,
        landing: MKCoordinateRegion,
        zoomDistance: CLLocationDistance,
        tempo: TransitionTempo,
        durationScale: Double,
        viewport: MapCameraViewport?,
        cameraPosition: Binding<MapCameraPosition>,
        onRegionUpdate: @escaping (MKCoordinateRegion) -> Void
    ) {
        hasUnsettledNativeFlight = true
        let id = UUID()
        activeTransitionID = id
        stagedLandingRegion = viewport?.framed(landing) ?? landing
        let base = tempo.durations
        // The original lift is intentionally handed over mid-animation.
        // Retiming that handoff changes MapKit's starting zoom for the cruise
        // and can paradoxically make a close-up departure faster. Preserve it.
        let durations = (zoomOut: base.zoomOut,
                         travel: base.travel * durationScale,
                         prefetchHold: base.prefetchHold,
                         zoomIn: base.zoomIn * durationScale)
        transitionEndsAt = CACurrentMediaTime() + durations.zoomOut + durations.travel + durations.zoomIn
        let liftFraction = tempo == .cinematic ? 0.38 : 0.26
        let liftCenter = current.center.interpolated(to: target.center, fraction: liftFraction)
        let liftPitch: CGFloat = tempo == .cinematic ? 36 : 0
        let cruisePitch: CGFloat = tempo == .cinematic ? 36 : 0

        // Keep the original MapKit camera animation, not independently
        // interpolated keyframes. Equal endpoints/easing numbers do not give
        // those two transports the same visible zoom or phase transitions.
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
            self.transitionEndsAt = CACurrentMediaTime() + durations.travel + durations.zoomIn
            let cruiseCamera = MapCamera(centerCoordinate: target.center,
                distance: zoomDistance, heading: 0, pitch: cruisePitch)
            self.scheduleDive(
                after: durations.travel,
                id: id,
                cruiseCamera: cruiseCamera,
                departure: current.center,
                target: landing,
                durations: durations,
                viewport: viewport,
                cameraPosition: cameraPosition,
                onRegionUpdate: onRegionUpdate
            )
            withAnimation(smoothAnimation(duration: durations.travel)) {
                cameraPosition.wrappedValue = .camera(cruiseCamera)
            }
        }
    }

    private func scheduleDive(
        after cruiseDuration: Double,
        id: UUID,
        cruiseCamera: MapCamera,
        departure: CLLocationCoordinate2D,
        target: MKCoordinateRegion,
        durations: (zoomOut: Double, travel: Double, prefetchHold: Double, zoomIn: Double),
        viewport: MapCameraViewport?,
        cameraPosition: Binding<MapCameraPosition>,
        onRegionUpdate: @escaping (MKCoordinateRegion) -> Void
    ) {
        let gateID = UUID()
        // Preserve the lift/travel blend and the chosen minimum cruise time.
        // Native MapKit can take longer to climb out of a close-up than the
        // requested animation duration. Switching to a region before the
        // cruise actually arrives interrupts it with a visible teleport.
        pendingDive = PendingDive(id: gateID, transitionID: id,
            cruiseCamera: cruiseCamera,
            departure: departure,
            centerTolerance: max(20, min(target.dominantSpanMeters * 0.1, 500)),
            earliestStart: CACurrentMediaTime() + cruiseDuration,
            observationRevision: cameraObservationRevision,
            begin: { [weak self] isRecovery in
                guard let self, self.activeTransitionID == id else { return }
                self.completeDive(
                    to: target,
                    with: isRecovery ? max(durations.zoomIn, 0.55) : durations.zoomIn,
                    transitionID: id,
                    viewport: viewport,
                    cameraPosition: cameraPosition,
                    onRegionUpdate: onRegionUpdate
                )
            })
        DispatchQueue.main.asyncAfter(deadline: .now() + cruiseDuration) { [weak self] in
            guard let self, self.pendingDive?.id == gateID else { return }
            self.beginDiveIfReady()
        }
        // Globe views can settle at a renderer-adjusted height without ever
        // satisfying the exact cruise/whole-route gate (the departure can be
        // on the other side of Earth). Finish an owned, settled arrival rather
        // than abandoning the user at continental zoom. Missing observations
        // or a map that never reached the destination still release ownership.
        DispatchQueue.main.asyncAfter(deadline: .now() + cruiseDuration + 3) { [weak self] in
            guard let self, self.activeTransitionID == id,
                  let gate = self.pendingDive, gate.id == gateID,
                  !gate.isScheduled else { return }
            if self.canRecoverSettledDive(gate) {
                self.queueDive(gate, recoveringFromAdjustedOverview: true)
                return
            }
            self.cancelActiveTransition()
        }
    }

    private func beginDiveIfReady() {
        guard let gate = pendingDive, !gate.isScheduled,
              activeTransitionID == gate.transitionID,
              CACurrentMediaTime() >= gate.earliestStart,
              cameraObservationRevision != gate.observationRevision,
              let camera = visibleCamera,
              camera.centerCoordinate.distance(to: gate.cruiseCamera.centerCoordinate) <= gate.centerTolerance
        else { return }
        let reachedDistance = abs(camera.distance - gate.cruiseCamera.distance)
            <= max(20, gate.cruiseCamera.distance * 0.02)
        // At globe scale MapKit can clamp distance for the destination's
        // latitude/viewport. Accept its settled, adjusted overview only when
        // the whole route already fits on screen. A stray onEnd during an
        // unfinished close-up is not enough to permit the landing.
        let reachedNativeOverview = gate.nativeEnded
            && visibleRegion?.contains(gate.departure, insetFraction: 0.92) == true
            && visibleRegion?.contains(gate.cruiseCamera.centerCoordinate, insetFraction: 0.92) == true
        guard reachedDistance || reachedNativeOverview else { return }
        queueDive(gate, recoveringFromAdjustedOverview: false)
    }

    private func canRecoverSettledDive(_ gate: PendingDive) -> Bool {
        // An old onEnd, a missing map, or an intermediate moving sample is not
        // authority to land. User gestures and newer selections also revoke the
        // flight before this path can run, through activeTransitionID.
        gate.nativeEnded
            && cameraObservationRevision != gate.observationRevision
            && visibleRegion?.contains(gate.cruiseCamera.centerCoordinate, insetFraction: 0.92) == true
    }

    private func queueDive(_ pending: PendingDive, recoveringFromAdjustedOverview: Bool) {
        var gate = pending
        gate.isScheduled = true
        pendingDive = gate
        // Do not publish another camera command inside MapKit's observation.
        // A replacement/user gesture can still cancel this queued handoff.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeTransitionID == gate.transitionID,
                  self.pendingDive?.id == gate.id else { return }
            self.pendingDive = nil
            gate.begin(recoveringFromAdjustedOverview)
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
        hasUnsettledNativeFlight = true
        hasIssuedLanding = true
        let framedTarget = viewport?.framed(target) ?? target
        transitionEndsAt = CACurrentMediaTime() + duration
        withAnimation(smoothAnimation(duration: duration)) {
            cameraPosition.wrappedValue = .region(framedTarget)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.activeTransitionID == id else { return }
            self.finishScheduledStages()
            onRegionUpdate(framedTarget)
        }
    }

    private func cityClamp(_ region: MKCoordinateRegion) -> MKCoordinateRegion {
        let meters = clamp(region.dominantSpanMeters, lower: 20_000, upper: 60_000)
        return MKCoordinateRegion(center: region.center, latitudinalMeters: meters, longitudinalMeters: meters)
    }
}

/// A gentle, bounded slowdown based on how many current screen spans a hop
/// crosses. Close moves stay crisp; even a very tight starting zoom adds no
/// more than 25%. There are no geographic cutoffs or per-frame retiming.
enum MapFlightPacing {
    static func durationScale(travelDistance: CLLocationDistance,
                              visibleSpan: CLLocationDistance) -> Double {
        guard travelDistance.isFinite, travelDistance > 0,
              visibleSpan.isFinite, visibleSpan > 0 else { return 1 }
        let extraScreens = max(0, travelDistance / max(visibleSpan, 1) - 0.5)
        return 1 + 0.25 * (1 - 2 / (extraScreens + 2))
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
    func matchesFittedLanding(_ target: MKCoordinateRegion) -> Bool {
        guard target.span.latitudeDelta > 0, target.span.longitudeDelta > 0,
              center.distance(to: target.center) < max(5, min(50, target.dominantSpanMeters * 0.02))
        else { return false }
        // MapKit expands one axis to fit the view's aspect ratio; the other
        // axis remains at the requested scale. A cruise at the same center
        // but a much wider scale must not count as a completed landing.
        let fittedScale = min(span.latitudeDelta / target.span.latitudeDelta,
                              span.longitudeDelta / target.span.longitudeDelta)
        return abs(fittedScale - 1) < 0.05
    }

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
        let rawLongitude = coordinate.longitude - center.longitude
        let lonDelta = (rawLongitude + 540).truncatingRemainder(dividingBy: 360) - 180

        return abs(latDelta) <= latRadius && abs(lonDelta) <= lonRadius
    }
}
