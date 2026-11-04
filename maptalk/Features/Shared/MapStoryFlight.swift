import MapKit
import SwiftUI

/// Observe the flight at the animator's own view boundary. The main map also
/// redraws its selection, annotations and sheet in this update; those must not
/// swallow the camera request's transaction.
struct MapStoryFlightModifier: ViewModifier {
    @ObservedObject var controller: MapFlightController
    let proxy: MapProxy

    func body(content: Content) -> some View {
        content.mapCameraKeyframeAnimator(trigger: controller.storyFlight?.id) { camera in
            storyFlightKeyframes(controller.storyFlight.map {
                $0.plan(from: camera, cameraForRegion: { proxy.camera(framing: $0) })
            })
        }
    }
}

/// One intent, resolved against MapKit's live camera when the animation starts.
/// Ordinary map/search flights continue to use MapFlightController's old path.
struct MapStoryFlightRequest {
    let id: UUID
    let destination: MKCoordinateRegion
    let previousCoordinate: CLLocationCoordinate2D
    let viewport: MapCameraViewport?
    let isRetarget: Bool
    let isGlobal: Bool

    var usesGlobalPlan: Bool {
        isGlobal || previousCoordinate.distance(to: destination.center) > 2_000_000
            || abs(previousCoordinate.longitude - destination.center.longitude) > 180
    }

    /// Keep the nearby rhythm, then lengthen continuously with the logical
    /// route. Framing and an interrupted zoom cannot switch speed bands.
    var duration: Double {
        let hop = previousCoordinate.distance(to: destination.center)
        if usesGlobalPlan {
            if hop <= 12_000 && !isRetarget { return MapStoryFlightPlan.duration }
            return min(5.2, 3.2 + 0.9 * log2(max(2_000_000, hop) / 2_000_000))
        }
        guard hop > 12_000 else { return MapStoryFlightPlan.duration }
        return min(3.2, MapStoryFlightPlan.duration + 0.4 * log2(hop / 12_000))
    }

    init(id: UUID = UUID(), destination: MKCoordinateRegion,
         previousCoordinate: CLLocationCoordinate2D, viewport: MapCameraViewport?,
         isRetarget: Bool = false, isGlobal: Bool = false) {
        self.id = id
        self.destination = destination
        self.previousCoordinate = previousCoordinate
        self.viewport = viewport
        self.isRetarget = isRetarget
        self.isGlobal = isGlobal
    }

    func plan(from camera: MapCamera,
              cameraForRegion: (MKCoordinateRegion) -> MapCamera) -> MapStoryFlightPlan {
        let landing = cameraForRegion(viewport?.framed(destination) ?? destination)
        if usesGlobalPlan {
            // Framing belongs to the city-scale endpoints. Multiplying its
            // Mercator offset by a globe-scale altitude bends the route away
            // from both places, particularly across latitude bands.
            let trajectory = MapStoryGlobalTrajectory(start: camera, landing: landing,
                                                      totalDuration: duration)
            return MapStoryFlightPlan(start: camera, landing: landing,
                overviewDistance: trajectory.peakDistance, offsetPerDistance: 0,
                startFocus: MKMapPoint(camera.centerCoordinate),
                endFocus: MKMapPoint(landing.centerCoordinate), totalDuration: duration,
                globalTrajectory: trajectory)
        }
        // Interpolate the focus of the UNCOVERED map, not the full-screen
        // center. Its framing offset scales continuously with camera distance.
        // Otherwise a tall card forces a huge zoom to fit pins below a hidden
        // screen center, or a separate correction at the end of the flight.
        let destinationPoint = MKMapPoint(destination.center)
        let landingPoint = MKMapPoint(landing.centerCoordinate)
        let offsetPerDistance = (landingPoint.y - destinationPoint.y) / max(1, landing.distance)
        let startPoint = MKMapPoint(camera.centerCoordinate)
        let startFocus = MKMapPoint(x: startPoint.x,
                                   y: startPoint.y - offsetPerDistance * camera.distance)
        let t = MapStoryFlightPlan.liftDuration / MapStoryFlightPlan.duration
        let progress = t * t * (3 - 2 * t)
        let peakFocus = MKMapPoint(x: startFocus.x + (destinationPoint.x - startFocus.x) * progress,
                                  y: startFocus.y + (destinationPoint.y - startFocus.y) * progress)
        let overviewRegion = overviewRegion(center: peakFocus.coordinate)
        let overview = cameraForRegion(viewport?.framed(overviewRegion) ?? overviewRegion)
        let overviewDistance = max(overview.distance * 1.08, landing.distance * 1.45,
                                   camera.distance * (isRetarget ? 1 : 1.25))
        return MapStoryFlightPlan(start: camera, landing: landing,
            overviewDistance: overviewDistance, offsetPerDistance: offsetPerDistance,
            startFocus: startFocus, endFocus: destinationPoint, totalDuration: duration)
    }

    private func overviewRegion(center: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let size = viewport?.size ?? CGSize(width: 400, height: 800)
        let width = max(1, size.width)
        let height = max(1, size.height)
        let origin = MKMapPoint(center)
        // Space for pin silhouettes, in addition to the existing sheet/chrome.
        let horizontal = max(1, width / 2 - min(28, width * 0.1))
        let visibleHeight = max(1, height - (viewport?.topInset ?? 0) - (viewport?.bottomInset ?? 0))
        let vertical = max(1, visibleHeight / 2 - min(24, visibleHeight * 0.1))
        var scale: Double = 1
        for coordinate in [previousCoordinate, destination.center] {
            let point = MKMapPoint(coordinate)
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            scale = max(scale, abs(dx) / horizontal, abs(dy) / vertical)
        }
        return MKCoordinateRegion(MKMapRect(x: origin.x - scale * width / 2,
            y: origin.y - scale * height / 2, width: scale * width, height: scale * height))
    }
}

struct MapStoryFlightPlan {
    static let duration = 1.2
    static let liftDuration = 0.42
    static let overviewDuration = 0.12
    static let landingDuration = duration - liftDuration - overviewDuration

    let start: MapCamera
    let landing: MapCamera
    let overviewDistance: CLLocationDistance
    let offsetPerDistance: Double
    let startFocus: MKMapPoint
    let endFocus: MKMapPoint
    let totalDuration: Double
    var globalTrajectory: MapStoryGlobalTrajectory? = nil
    var isGlobal: Bool { globalTrajectory != nil }
    var liftTime: Double { totalDuration * (isGlobal ? 0.40 : Self.liftDuration / Self.duration) }
    var overviewTime: Double { totalDuration * (isGlobal ? 0.20 : Self.overviewDuration / Self.duration) }
    var landingTime: Double { totalDuration - liftTime - overviewTime }

    var landingHeading: CLLocationDirection {
        let delta = (landing.heading - start.heading + 540).truncatingRemainder(dividingBy: 360) - 180
        return start.heading + delta
    }

    func visibleFocus(of camera: MapCamera) -> CLLocationCoordinate2D {
        if isGlobal { return camera.centerCoordinate }
        let point = MKMapPoint(camera.centerCoordinate)
        return MKMapPoint(x: point.x, y: point.y - offsetPerDistance * camera.distance).coordinate
    }

    struct CenterKeyframe {
        let coordinate: CLLocationCoordinate2D
        let duration: Double
        let startVelocity: CLLocationCoordinate2D
        let endVelocity: CLLocationCoordinate2D
        // ±180° are the same physical point. Reset the numeric longitude there
        // rather than interpolating a 359° turn through the opposite hemisphere.
        var resetBefore: CLLocationCoordinate2D? = nil
    }

    var centerKeyframes: [CenterKeyframe] {
        if let globalTrajectory { return globalTrajectory.centerKeyframes }
        let stops = [(liftTime, overviewDistance),
                     (liftTime + overviewTime, overviewDistance),
                     (totalDuration, landing.distance)]
        var previousTime = 0.0
        var previousVelocity = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        return stops.map { time, distance in
            let t = time / totalDuration
            let progress = t * t * (3 - 2 * t)
            let point = MKMapPoint(x: startFocus.x + (endFocus.x - startFocus.x) * progress,
                y: startFocus.y + (endFocus.y - startFocus.y) * progress + offsetPerDistance * distance)
            let coordinate = time == totalDuration ? landing.centerCoordinate : point.coordinate
            // At each distance-track boundary its velocity is zero. Match the
            // remaining focus velocity across BOTH center segments, so they do
            // not stop/restart as the camera changes from rising to descending.
            let velocityScale = 6 * t * (1 - t) / totalDuration
            let dx = (endFocus.x - startFocus.x) * velocityScale
            let dy = (endFocus.y - startFocus.y) * velocityScale
            let latitude = coordinate.latitude * .pi / 180
            let velocity = CLLocationCoordinate2D(
                latitude: -dy * cos(latitude) * 360 / MKMapRect.world.height,
                longitude: dx * 360 / MKMapRect.world.width)
            let frame = CenterKeyframe(coordinate: coordinate, duration: time - previousTime,
                                      startVelocity: previousVelocity, endVelocity: velocity)
            previousTime = time
            previousVelocity = velocity
            return frame
        }
    }
}

/// A single native global flight. Scale is perceptual (log distance), while
/// geographic motion follows the standard map's wrapped Mercator projection.
/// The sampled Hermite
/// tracks share derivatives; they do not stop at each waypoint or publish
/// SwiftUI state on every display frame.
struct MapStoryGlobalTrajectory {
    // Traverse while the map is high, then descend over a stationary
    // destination instead of requesting new geography late in the landing.
    static let centerTravelRange = 0.28...0.72

    struct DistanceKeyframe {
        let distance: Double
        let duration: Double
        let startVelocity: Double
        let endVelocity: Double
    }

    let start: MapCamera
    let landing: MapCamera
    let totalDuration: Double
    let peakDistance: Double
    private let cruiseDistance: Double
    private let route: MapStoryProjectedRoute

    init(start: MapCamera, landing: MapCamera, totalDuration: Double) {
        self.start = start
        self.landing = landing
        self.totalDuration = totalDuration
        route = MapStoryProjectedRoute(from: start.centerCoordinate, to: landing.centerCoordinate)
        let desiredPeak = min(9_000_000, max(landing.distance * 1.45,
            start.centerCoordinate.distance(to: landing.centerCoordinate) * 0.65))
        // Retargeting an already lifted camera must not kick it higher or
        // remain stuck at the old altitude merely to replay a takeoff. Its
        // first scale phase gently descends toward the new useful overview.
        cruiseDistance = max(desiredPeak, landing.distance)
        peakDistance = max(cruiseDistance, start.distance)
    }

    func center(at time: Double) -> CLLocationCoordinate2D {
        let fraction = min(1, max(0, time / totalDuration))
        let travel = Self.centerTravelRange
        let progress = Self.smooth((fraction - travel.lowerBound) / (travel.upperBound - travel.lowerBound))
        return route.coordinate(at: progress)
    }

    func distance(at time: Double) -> Double { distanceSample(at: time).value }

    private func distanceSample(at time: Double) -> (value: Double, velocity: Double) {
        let time = min(totalDuration, max(0, time))
        let lower = max(1, start.distance)
        let upper = max(1, landing.distance)
        let peak = max(1, cruiseDistance)
        let from: Double
        let to: Double
        let phase: Double
        let phaseDuration: Double
        if time < totalDuration * 0.40 {
            from = lower; to = peak
            phaseDuration = totalDuration * 0.40
            phase = time / phaseDuration
        } else if time <= totalDuration * 0.60 {
            return (peak, 0)
        } else {
            from = peak; to = upper
            phaseDuration = totalDuration * 0.40
            phase = (time - totalDuration * 0.60) / phaseDuration
        }
        let logDelta = log(to) - log(from)
        let value = exp(log(from) + logDelta * Self.smooth(phase))
        return (value, value * logDelta * Self.smoothDerivative(phase) / phaseDuration)
    }

    private var sampleTimes: [Double] {
        // Include every phase and velocity-ramp boundary exactly, not just a
        // regular cadence. Keep the existing dense native distance samples.
        let travel = Self.centerTravelRange
        let fractions = (0...64).map { Double($0) / 64 }
            + [0.10, 0.30, 0.40, 0.60, 0.70, 0.90,
               travel.lowerBound, travel.upperBound,
               travel.lowerBound + (travel.upperBound - travel.lowerBound) * 0.25,
               travel.lowerBound + (travel.upperBound - travel.lowerBound) * 0.75]
        return Array(Set(fractions)).sorted().map { $0 * totalDuration }
    }

    var distanceKeyframes: [DistanceKeyframe] {
        let times = sampleTimes
        return zip(times, times.dropFirst()).map { beginning, ending in
            let a = distanceSample(at: beginning)
            let b = distanceSample(at: ending)
            return .init(distance: b.value, duration: ending - beginning,
                         startVelocity: a.velocity, endVelocity: b.velocity)
        }
    }

    private func centerVelocity(at time: Double) -> CLLocationCoordinate2D {
        let travel = Self.centerTravelRange
        guard time > totalDuration * travel.lowerBound, time < totalDuration * travel.upperBound else {
            return .init(latitude: 0, longitude: 0)
        }
        let delta = totalDuration * 0.000_01
        let a = center(at: time - delta)
        let b = center(at: time + delta)
        return .init(latitude: (b.latitude - a.latitude) / (2 * delta),
                     longitude: Self.longitudeDelta(from: a.longitude, to: b.longitude) / (2 * delta))
    }

    var centerKeyframes: [MapStoryFlightPlan.CenterKeyframe] {
        var frames: [MapStoryFlightPlan.CenterKeyframe] = []
        var pendingReset: CLLocationCoordinate2D?
        let times = sampleTimes
        for (beginning, ending) in zip(times, times.dropFirst()) {
            let a = center(at: beginning)
            let b = center(at: ending)
            if abs(b.longitude - a.longitude) > 180 {
                // Locate the actual date-line crossing on the projected path.
                // All emitted coordinates stay within CoreLocation's valid
                // range; no reliance on undocumented >180° normalization.
                var low = beginning
                var high = ending
                for _ in 0..<45 {
                    let middle = (low + high) / 2
                    if abs(center(at: middle).longitude - a.longitude) <= 180 { low = middle }
                    else { high = middle }
                }
                let crossing = (low + high) / 2
                let latitude = center(at: crossing).latitude
                let before = CLLocationCoordinate2D(latitude: latitude,
                    longitude: a.longitude >= 0 ? 180 : -180)
                let after = CLLocationCoordinate2D(latitude: latitude, longitude: -before.longitude)
                if crossing - beginning > 0.000_000_1 {
                    frames.append(.init(coordinate: before, duration: crossing - beginning,
                        startVelocity: centerVelocity(at: beginning), endVelocity: centerVelocity(at: crossing),
                        resetBefore: pendingReset))
                    pendingReset = nil
                }
                pendingReset = after
                if ending - crossing > 0.000_000_1 {
                    frames.append(.init(coordinate: b, duration: ending - crossing,
                        startVelocity: centerVelocity(at: crossing), endVelocity: centerVelocity(at: ending),
                        resetBefore: pendingReset))
                    pendingReset = nil
                }
            } else {
                frames.append(.init(coordinate: b, duration: ending - beginning,
                    startVelocity: centerVelocity(at: beginning), endVelocity: centerVelocity(at: ending),
                    resetBefore: pendingReset))
                pendingReset = nil
            }
        }
        return frames
    }

    private static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        // Ease velocity in/out, with a steady middle instead of a bell-shaped
        // speed spike. Quintic position easing crammed 80% of a continent hop
        // into less than a second even though its endpoints were continuous.
        let edge = 0.25
        if t < edge {
            let u = t / edge
            return edge * (u * u * u - 0.5 * u * u * u * u) / (1 - edge)
        }
        if t > 1 - edge { return 1 - smooth(1 - t) }
        return (t - edge / 2) / (1 - edge)
    }

    private static func smoothDerivative(_ value: Double) -> Double {
        guard value > 0, value < 1 else { return 0 }
        let edge = 0.25
        let u = min(1, min(value, 1 - value) / edge)
        return u * u * (3 - 2 * u) / (1 - edge)
    }

    private static func longitudeDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}

/// The app uses a flat standard map, not a spherical globe. Travel through its
/// projected plane without a needless polar detour, wrapping only longitude.
private struct MapStoryProjectedRoute {
    let origin: CLLocationCoordinate2D
    let destination: CLLocationCoordinate2D
    private let from: MKMapPoint
    private let destinationY: Double
    private let longitudeDelta: Double

    init(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) {
        self.origin = origin
        self.destination = destination
        let world = MKMapRect.world
        let a = MKMapPoint(origin)
        let b = MKMapPoint(destination)
        // Internal projection stays finite even for a polar coordinate; retain
        // the caller's exact endpoints for MapKit's final camera framing.
        from = MKMapPoint(x: a.x, y: min(world.maxY, max(world.minY, a.y)))
        destinationY = min(world.maxY, max(world.minY, b.y))
        var delta = b.x - a.x
        // Keep the sign of an exact half-world tie. Reversing those endpoints
        // then takes the same path backwards instead of choosing another side.
        if delta > world.width / 2 { delta -= world.width }
        if delta < -world.width / 2 { delta += world.width }
        longitudeDelta = delta
    }

    func coordinate(at fraction: Double) -> CLLocationCoordinate2D {
        guard fraction > 0 else { return origin }
        guard fraction < 1 else { return destination }
        let width = MKMapRect.world.width
        var x = (from.x + longitudeDelta * fraction).truncatingRemainder(dividingBy: width)
        if x < 0 { x += width }
        return MKMapPoint(x: x, y: from.y + (destinationY - from.y) * fraction).coordinate
    }
}

/// Native tracks run inside MapKit: no per-frame SwiftUI state writes and no
/// timer that can kick an old landing back in after a new selection.
private struct StoryCenterKeyframe: KeyframeTrackContent {
    let frame: MapStoryFlightPlan.CenterKeyframe

    var body: some KeyframeTrackContent<CLLocationCoordinate2D> {
        if let reset = frame.resetBefore { MoveKeyframe(reset) } else {}
        CubicKeyframe(frame.coordinate, duration: frame.duration,
                      startVelocity: frame.startVelocity, endVelocity: frame.endVelocity)
    }
}

@KeyframesBuilder<MapCamera>
func storyFlightKeyframes(_ plan: MapStoryFlightPlan?) -> some Keyframes<MapCamera> {
    KeyframeTrack(\MapCamera.centerCoordinate) {
        if let plan {
            for frame in plan.centerKeyframes {
                StoryCenterKeyframe(frame: frame)
            }
        } else {}
    }
    KeyframeTrack(\MapCamera.distance) {
        if let plan {
            if let global = plan.globalTrajectory {
                for frame in global.distanceKeyframes {
                    CubicKeyframe(frame.distance, duration: frame.duration,
                                  startVelocity: frame.startVelocity, endVelocity: frame.endVelocity)
                }
            } else {
                CubicKeyframe(plan.overviewDistance, duration: plan.liftTime,
                              startVelocity: 0, endVelocity: 0)
                LinearKeyframe(plan.overviewDistance, duration: plan.overviewTime)
                CubicKeyframe(plan.landing.distance, duration: plan.landingTime,
                              startVelocity: 0, endVelocity: 0)
            }
        } else {}
    }
    KeyframeTrack(\MapCamera.heading) {
        if let plan {
            CubicKeyframe(plan.landingHeading, duration: plan.totalDuration,
                          startVelocity: 0, endVelocity: 0)
        } else {}
    }
    KeyframeTrack(\MapCamera.pitch) {
        if let plan {
            CubicKeyframe(plan.landing.pitch, duration: plan.totalDuration,
                          startVelocity: 0, endVelocity: 0)
        } else {}
    }
}
