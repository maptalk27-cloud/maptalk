#if os(iOS)
import Combine
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
                    }
                )
                .onAppear { loc.request() }
                .onReceive(loc.$lastLocation.compactMap { $0?.coordinate }) { coordinate in
                    handleLocationUpdate(coordinate)
                }
                .onReceive(nav.$routeCoordinates) { coordinates in
                    routes = coordinates.isEmpty ? [] : [RouteLine(coordinates: coordinates, colorIndex: 0)]
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
                            if let coordinate = loc.lastLocation?.coordinate {
                                followUser(to: coordinate)
                            } else {
                                loc.request()
                            }
                        }
                        HUDButton(systemName: "mappin.and.ellipse", enabled: true) {
                            guard let start = loc.lastLocation?.coordinate,
                                  let destination = mapCenter else { return }
                            nav.setDestination(destination)
                            nav.planRoute(from: start, to: destination, mode: .automobile)
                            followEnabled = false
                        }
                        HUDButton(systemName: "trash", enabled: true) {
                            routes.removeAll()
                            nav.destination = nil
                            nav.route = nil
                            nav.routeCoordinates = []
                            nav.etaText = nil
                            nav.distanceText = nil
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

    private func handleLocationUpdate(_ coordinate: CLLocationCoordinate2D) {
        if followEnabled {
            followUser(to: coordinate)
        }
        nav.considerReroute(current: coordinate)
    }

    private func followUser(to coordinate: CLLocationCoordinate2D) {
        var camera = MapCamera(centerCoordinate: coordinate, distance: followDistance)
        camera.heading = 0
        camera.pitch = 0
        withAnimation(.easeInOut) {
            position = .camera(camera)
        }
    }

    @MainActor
    private func bottomSafeAreaInset() -> CGFloat {
        guard let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first else { return 0 }
        return keyWindow.safeAreaInsets.bottom
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
