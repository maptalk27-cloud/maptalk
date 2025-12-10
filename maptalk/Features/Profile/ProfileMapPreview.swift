import MapKit
import SwiftUI

struct ProfileMapPreview: View {
    let pins: [ProfileViewModel.MapPin]
    let footprints: [ProfileViewModel.Footprint]
    let reels: [RealPost]
    let region: MKCoordinateRegion
    let isActive: Bool

    @State private var cameraPosition: MapCameraPosition
    @State private var spinLongitude: CLLocationDegrees
    @State private var spinPhase: SpinPhase = .north
    @State private var ticksRemaining: Int = 0
    @State private var phaseTicksTotal: Int = 0
    @StateObject private var cityResolver = TimelineCityResolver()

    private let spinLatitude: CLLocationDegrees
    private let globeDistance: CLLocationDistance = 20_000_000
    private let spinDuration: TimeInterval = 20
    private let spinFrameInterval: TimeInterval = 1.0 / 60.0
    private let transitionDuration: TimeInterval = 3.5
    private var previewTimelineSegments: [TimelineSegment] {
        let reelEvents = reels.map { real in
            TimelineEvent(
                id: real.id,
                date: real.createdAt,
                coordinate: real.center,
                kind: .reel(real, PreviewData.user(for: real.userId))
            )
        }

        let footprintEvents: [TimelineEvent] = footprints.compactMap { footprint in
            guard let visitDate = footprint.latestVisit else { return nil }
            return TimelineEvent(
                id: footprint.id,
                date: visitDate,
                coordinate: footprint.coordinate,
                kind: .poi(footprint.ratedPOI)
            )
        }

        let events = (reelEvents + footprintEvents).sorted { $0.date > $1.date }
        var segments: [TimelineSegment] = []
        for event in events {
            let label = cityResolver.label(for: event.coordinate, preferred: event.labelHint)
            if var last = segments.last, last.label == label {
                last.events.append(event)
                last.end = max(last.end, event.date)
                segments[segments.count - 1] = last
            } else {
                segments.append(
                    TimelineSegment(
                        label: label,
                        start: event.date,
                        end: event.date,
                        events: [event]
                    )
                )
            }
        }
        return segments
    }
    private var spinFrameNanoseconds: UInt64 {
        UInt64((spinFrameInterval * 1_000_000_000).rounded())
    }
    private var rotationTicks: Int {
        Int((spinDuration / spinFrameInterval).rounded())
    }
    private var latitudeTransitionTicks: Int {
        Int((transitionDuration / spinFrameInterval).rounded())
    }

    init(
        pins: [ProfileViewModel.MapPin],
        footprints: [ProfileViewModel.Footprint],
        reels: [RealPost],
        region: MKCoordinateRegion,
        isActive: Bool
    ) {
        self.pins = pins
        self.footprints = footprints
        self.reels = reels
        self.region = region
        self.isActive = isActive
        let latitude = Self.clampedLatitude(region.center.latitude)
        spinLatitude = latitude
        let startingLongitude = Self.wrappedLongitude(region.center.longitude)
        _spinLongitude = State(initialValue: startingLongitude)
        let camera = Self.makeCamera(latitude: latitude, longitude: startingLongitude, distance: globeDistance)
        _cameraPosition = State(initialValue: .camera(camera))
    }

    var body: some View {
        let showDetails = ProfileMapAnnotationZoomHelper.isClose(distance: globeDistance)

        VStack(spacing: 10) {
            Map(position: $cameraPosition, interactionModes: []) {
                if showDetails {
                    ForEach(reels) { real in
                        MapCircle(center: real.center, radius: real.radiusMeters)
                            .foregroundStyle(Theme.neonPrimary.opacity(0.18))
                            .stroke(Theme.neonPrimary.opacity(0.85), lineWidth: 1.5)
                        Annotation("", coordinate: real.center) {
                            RealMapThumbnail(real: real, user: PreviewData.user(for: real.userId), size: 38)
                        }
                    }
                    ForEach(pins) { pin in
                        Annotation("", coordinate: pin.coordinate) {
                            ProfileMapMarker(category: pin.category)
                        }
                    }
                } else {
                    ForEach(reels) { real in
                        Annotation("", coordinate: real.center) {
                            ProfileCollapsedReelMarker(real: real)
                        }
                    }
                    ForEach(pins) { pin in
                        Annotation("", coordinate: pin.coordinate) {
                            ProfileMapDotMarker(category: pin.category)
                        }
                    }
                }
            }
            .mapStyle(hybridMapStyle)
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 16, x: 0, y: 10)
            .task(id: isActive) {
                guard isActive else { return }
                await spinContinuously()
            }
            .animation(nil, value: cameraPosition)
            .environment(\.colorScheme, .light)

            if previewTimelineSegments.isEmpty == false {
                PreviewTimelineAxis(segments: previewTimelineSegments)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 180)
            }
        }
    }

    private func spinContinuously() async {
        let frameDelay = spinFrameNanoseconds
        await MainActor.run {
            startPhase(.north, resetLongitude: true)
        }
        while !Task.isCancelled {
            await MainActor.run {
                stepSpin()
            }
            do {
                try await Task.sleep(nanoseconds: frameDelay)
            } catch {
                break
            }
        }
    }

    @MainActor
    private func stepSpin() {
        if ticksRemaining <= 0 {
            let next = nextPhase(after: spinPhase)
            startPhase(next, resetLongitude: false)
        }
        let delta = spinDegreesPerTick
        let nextLongitude = Self.wrappedLongitude(spinLongitude + delta)
        spinLongitude = nextLongitude
        let camera = Self.makeCamera(latitude: currentLatitude, longitude: nextLongitude, distance: globeDistance)
        withTransaction(Transaction(animation: nil)) {
            cameraPosition = .camera(camera)
        }
        ticksRemaining -= 1
    }

    private var spinDegreesPerTick: CLLocationDegrees {
        (360 / spinDuration) * spinFrameInterval
    }

    private static func makeCamera(latitude: CLLocationDegrees, longitude: CLLocationDegrees, distance: CLLocationDistance) -> MapCamera {
        MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            distance: distance,
            heading: 0,
            pitch: 0
        )
    }

    private static func clampedLatitude(_ latitude: CLLocationDegrees) -> CLLocationDegrees {
        max(min(latitude, 70), -70)
    }

    private var currentLatitude: CLLocationDegrees {
        // Bias orbits toward the equator; north/south ranges overlap more for smoother swaps
        let northMagnitude = min(max(abs(spinLatitude), 20), 40)
        let southMagnitude = min(max(abs(spinLatitude), 15), 35)
        switch spinPhase {
        case .north:
            return northMagnitude
        case .south:
            return -southMagnitude
        case .transitionToSouth:
            let total = max(phaseTicksTotal, 1)
            let progress = easedProgress(1 - (Double(ticksRemaining) / Double(total)))
            let start = northMagnitude
            let end = -southMagnitude
            return start + (end - start) * progress
        case .transitionToNorth:
            let total = max(phaseTicksTotal, 1)
            let progress = easedProgress(1 - (Double(ticksRemaining) / Double(total)))
            let start = -southMagnitude
            let end = northMagnitude
            return start + (end - start) * progress
        }
    }

    private var hybridMapStyle: MapStyle {
        if #available(iOS 17.0, *) {
            return .hybrid(elevation: .realistic)
        }
        return .hybrid
    }

    private static func wrappedLongitude(_ longitude: CLLocationDegrees) -> CLLocationDegrees {
        var value = longitude
        if value > 180 {
            value -= 360
        } else if value < -180 {
            value += 360
        }
        return value
    }

    @MainActor
    private func startPhase(_ phase: SpinPhase, resetLongitude: Bool) {
        spinPhase = phase
        switch phase {
        case .north, .south:
            ticksRemaining = rotationTicks
            phaseTicksTotal = rotationTicks
        case .transitionToSouth, .transitionToNorth:
            ticksRemaining = latitudeTransitionTicks
            phaseTicksTotal = latitudeTransitionTicks
        }
        if resetLongitude {
            let startLongitude = Self.wrappedLongitude(region.center.longitude)
            spinLongitude = startLongitude
        }
        let camera = Self.makeCamera(latitude: currentLatitude, longitude: spinLongitude, distance: globeDistance)
        cameraPosition = .camera(camera)
    }

    private func nextPhase(after phase: SpinPhase) -> SpinPhase {
        switch phase {
        case .north:
            return .transitionToSouth
        case .transitionToSouth:
            return .south
        case .south:
            return .transitionToNorth
        case .transitionToNorth:
            return .north
        }
    }

    private func easedProgress(_ linear: Double) -> Double {
        // Smoothstep easing to avoid robotic motion
        return linear * linear * (3 - 2 * linear)
    }

    private enum SpinPhase {
        case north
        case transitionToSouth
        case south
        case transitionToNorth
    }
}
