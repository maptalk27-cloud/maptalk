#if os(iOS)
import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var loc = LocationManager()
    @StateObject private var nav = NavigationModel()

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
    )
    @State private var routes: [RouteLine] = []
    @State private var mapCenter: CLLocationCoordinate2D?
    @State private var followEnabled = true
    @State private var isShowingUser = true
    @State private var lastCameraCoordinate: CLLocationCoordinate2D? = nil
    @State private var lastCameraHeading: CLLocationDirection? = nil
    @State private var lastCameraDistance: CLLocationDistance? = nil
    @State private var lastHeadingTimestamp: Date? = nil
    @State private var lastDistanceTimestamp: Date? = nil
    @State private var lastLocationUpdate: Date? = nil
    private let followDistance: CLLocationDistance = 1_200

    var body: some View {
        NavigationStack {
            ZStack {
                RouteMapView(
                    position: $position,
                    routes: routes,
                    showUser: isShowingUser,
                    onCameraChange: { region in
                        mapCenter = region.center
                    },
                    onUserInteraction: {
                        followEnabled = false
                        lastHeadingTimestamp = nil
                        lastDistanceTimestamp = nil
                    }
                )
                .onAppear { loc.request() }
                .onReceive(loc.$lastLocation.compactMap { $0 }) { location in
                    handleLocationUpdate(location)
                }
                .onReceive(nav.$routeCoordinates) { coordinates in
                    routes = coordinates.isEmpty ? [] : [RouteLine(coordinates: coordinates, colorIndex: 0)]
                    if !coordinates.isEmpty {
                        followEnabled = true
                        lastCameraHeading = nil
                        lastHeadingTimestamp = nil
                        lastCameraDistance = nil
                        lastDistanceTimestamp = nil
                    }
                }

                NeonOverlay()

                VStack(spacing: 14) {
                    NeonTripCard()
                    Spacer()
                }

                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        HUDButton(systemName: "location.fill", enabled: true) {
                            followEnabled = true
                            if let location = loc.lastLocation {
                                let isNavigating = nav.route != nil
                                let heading = isNavigating ? nav.smoothedHeading(for: location) : nil
                                let pitch = isNavigating ? navigationPitch : 0
                                let distance = isNavigating ? navigationFollowDistance : followDistance
                                let coord = nav.smoothedCoordinate(after: location.coordinate)
                                followUser(to: coord, heading: heading, pitch: pitch, distance: distance)
                            } else {
                                loc.request()
                            }
                        }
                        HUDButton(systemName: "mappin.and.ellipse", enabled: true) {
                            guard let start = loc.lastLocation?.coordinate,
                                  let destination = mapCenter else { return }
                            nav.setDestination(destination)
                            nav.planRoute(from: start, to: destination, mode: .automobile)
                            followEnabled = true
                            lastCameraHeading = nil
                            lastHeadingTimestamp = nil
                            lastCameraDistance = nil
                            lastDistanceTimestamp = nil
                        }
                        HUDButton(systemName: "trash", enabled: true) {
                            routes.removeAll()
                            nav.destination = nil
                            nav.route = nil
                            nav.routeCoordinates = []
                            nav.etaText = nil
                            nav.distanceText = nil
                            nav.resetFilters(resetHeading: true)
                            lastCameraHeading = nil
                            lastHeadingTimestamp = nil
                            lastCameraDistance = nil
                            lastDistanceTimestamp = nil
                        }
                    }
                    .padding(.trailing)
                    .padding(.bottom, nav.route != nil ? 160 : 0)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                if nav.route != nil {
                    VStack(spacing: 0) {
                        Spacer()
                        TripInfoBox(
                            etaText: nav.etaText,
                            distanceText: nav.distanceText,
                            isComputing: nav.isComputing
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, horizontalEdgeInset())
                        .padding(.bottom, bottomEdgeInset())
                        .ignoresSafeArea(edges: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationBarHidden(true)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: nav.route != nil)
        }
    }

    private func handleLocationUpdate(_ location: CLLocation) {
        let targetCoordinate = nav.smoothedCoordinate(after: location.coordinate)
        if let lastUpdate = lastLocationUpdate,
           Date().timeIntervalSince(lastUpdate) > locationDropThreshold,
           nav.route != nil {
            followEnabled = true
        }
        lastLocationUpdate = Date()

        if followEnabled {
            let isNavigating = nav.route != nil
            let heading = isNavigating ? nav.smoothedHeading(for: location) : nil
            let pitch = isNavigating ? navigationPitch : 0
            let distance = isNavigating ? navigationFollowDistance : followDistance
            followUser(to: targetCoordinate, heading: heading, pitch: pitch, distance: distance)
        }
        nav.considerReroute(current: location.coordinate)
    }

    private func followUser(to coordinate: CLLocationCoordinate2D,
                            heading: CLLocationDirection?,
                            pitch: CGFloat,
                            distance: CLLocationDistance) {
        let timestamp = Date()
        let desiredHeading = heading ?? lastCameraHeading ?? 0
        let appliedHeading = throttledHeading(toward: desiredHeading, at: timestamp)
        let appliedDistance = throttledDistance(toward: distance, at: timestamp)

        var camera = MapCamera(centerCoordinate: coordinate, distance: appliedDistance)
        camera.heading = appliedHeading
        camera.pitch = pitch

        let duration = animationDuration(for: signedAngularDifference(from: lastCameraHeading ?? appliedHeading, to: appliedHeading))
        withAnimation(.linear(duration: duration)) {
            position = .camera(camera)
        }

        lastCameraCoordinate = coordinate
        lastCameraHeading = appliedHeading
        lastCameraDistance = appliedDistance
        lastHeadingTimestamp = timestamp
        lastDistanceTimestamp = timestamp
    }

    private func followUser(to coordinate: CLLocationCoordinate2D) {
        followUser(to: coordinate, heading: nil, pitch: 0, distance: followDistance)
    }

    @MainActor
    private func bottomSafeAreaInset() -> CGFloat {
        guard let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return 0 }
        return keyWindow.safeAreaInsets.bottom
    }

    private let navigationFollowDistance: CLLocationDistance = 750
    private let navigationPitch: CGFloat = 55
    private let locationDropThreshold: TimeInterval = 4.0
    private let maxHeadingRateDegreesPerSecond: CLLocationDirection = 60
    private let maxDistanceRateMetersPerSecond: CLLocationDistance = 500
    private let minAnimationDuration: Double = 0.18
    private let maxAnimationDuration: Double = 0.55

    private func throttledHeading(toward desired: CLLocationDirection, at timestamp: Date) -> CLLocationDirection {
        let base = lastCameraHeading ?? desired
        let lastTime = lastHeadingTimestamp ?? timestamp
        let dt = max(timestamp.timeIntervalSince(lastTime), 0.016)
        let allowedDelta = maxHeadingRateDegreesPerSecond * dt
        let signedDiff = signedAngularDifference(from: base, to: desired)
        let clamped = clamp(signedDiff, min: -allowedDelta, max: allowedDelta)
        let result = normalizeHeading(base + clamped)
        return result
    }

    private func throttledDistance(toward desired: CLLocationDistance, at timestamp: Date) -> CLLocationDistance {
        let base = lastCameraDistance ?? desired
        let lastTime = lastDistanceTimestamp ?? timestamp
        let dt = max(timestamp.timeIntervalSince(lastTime), 0.016)
        let allowedDelta = maxDistanceRateMetersPerSecond * dt
        let delta = desired - base
        let clamped = clamp(delta, min: -allowedDelta, max: allowedDelta)
        return base + clamped
    }

    private func animationDuration(for signedDelta: CLLocationDirection) -> Double {
        let magnitude = min(abs(signedDelta), 180)
        let normalized = magnitude / 180
        return minAnimationDuration + Double(normalized) * (maxAnimationDuration - minAnimationDuration)
    }

    private func signedAngularDifference(from start: CLLocationDirection, to end: CLLocationDirection) -> CLLocationDirection {
        let diff = (end - start).truncatingRemainder(dividingBy: 360)
        let adjusted = diff > 180 ? diff - 360 : diff < -180 ? diff + 360 : diff
        return adjusted
    }

    private func normalizeHeading(_ heading: CLLocationDirection) -> CLLocationDirection {
        var value = heading.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    private func clamp<T: Comparable>(_ value: T, min: T, max: T) -> T {
        if value < min { return min }
        if value > max { return max }
        return value
    }

    private func horizontalEdgeInset() -> CGFloat {
        // Try to mimic native Apple Maps card spacing
        max(deviceCornerRadiusPadding(), 16)
    }

    private func bottomEdgeInset() -> CGFloat {
        let safeInset = bottomSafeAreaInset()
        // Align with native feel; tuck close to the home indicator
        if safeInset > 0 {
            return max(safeInset - 42, -8)
        } else {
            return 6
        }
    }

    private func deviceCornerRadiusPadding() -> CGFloat {
        // Estimate inset needed so rounded card visually aligns to display curve
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return 22 }
        // Use safe-area bottom to infer device corner radius; keep spacing consistent on flat devices.
        let bottomInset = window.safeAreaInsets.bottom
        if bottomInset > 20 {
            return max(bottomInset - 18, 12)
        } else {
            return 16
        }
    }

}

#Preview { ContentView() }

#else
import SwiftUI
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("This sample targets iOS.")
            Text("Choose an iPhone simulator in Xcode's toolbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
#Preview { ContentView() }
#endif
