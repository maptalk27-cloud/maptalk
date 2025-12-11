import MapKit
import SwiftUI

struct ProfileMapPreview: View {
    let pins: [ProfileViewModel.MapPin]
    let footprints: [ProfileViewModel.Footprint]
    let reels: [RealPost]
    let region: MKCoordinateRegion

    @State private var cameraPosition: MapCameraPosition
    @StateObject private var cityResolver = TimelineCityResolver()

    private let globeDistance: CLLocationDistance = 20_000_000
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

    init(
        pins: [ProfileViewModel.MapPin],
        footprints: [ProfileViewModel.Footprint],
        reels: [RealPost],
        region: MKCoordinateRegion
    ) {
        self.pins = pins
        self.footprints = footprints
        self.reels = reels
        self.region = region
        let latitude = Self.clampedLatitude(region.center.latitude)
        let startingLongitude = Self.wrappedLongitude(region.center.longitude)
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
            .animation(nil, value: cameraPosition)
            .environment(\.colorScheme, .light)

            if previewTimelineSegments.isEmpty == false {
                PreviewTimelineAxis(segments: previewTimelineSegments)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 180)
            }
        }
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

}
