#if os(iOS)
import Combine
import MapKit
import SwiftUI

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

                VStack(spacing: 8) {
                    NeonTripCard(
                        etaText: nav.etaText,
                        distanceText: nav.distanceText,
                        isComputing: nav.isComputing
                    )
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
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .navigationBarHidden(true)
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
