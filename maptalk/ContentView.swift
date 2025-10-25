// SwiftUI Map Starter – iOS ONLY (guards out macOS build)
// Replace ContentView.swift with this. If you see macOS errors, you're on the wrong scheme—
// this file compiles only for iOS and shows a message on macOS.
// Info.plist: add NSLocationWhenInUseUsageDescription (string message for location permission).

#if os(iOS)
import SwiftUI
import MapKit
import CoreLocation
import Combine

// MARK: - Model
struct Pin: Identifiable, Hashable, Equatable {
    let id = UUID()
    var title: String
    var coordinate: CLLocationCoordinate2D

    static func == (lhs: Pin, rhs: Pin) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Location Manager (iOS)
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastLocation: CLLocation? = nil

    private let manager = CLLocationManager()

    override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func request() {
        if authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        self.authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
    }
}

// MARK: - ContentView (iOS)
struct ContentView: View {
    @StateObject private var loc = LocationManager()

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )

    @State private var pins: [Pin] = []
    @State private var searchText: String = ""
    @State private var isShowingUser: Bool = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                // Search Bar
                HStack {
                    TextField("Search places (e.g. 'coffee')", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { performSearch() }
                    Button("Go") { performSearch() }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                // Map (iOS 17 / Xcode 15 compatible)
                Map(coordinateRegion: $region, interactionModes: .all, showsUserLocation: isShowingUser, annotationItems: pins) { pin in
                    MapAnnotation(coordinate: pin.coordinate) {
                        ZStack {
                            Circle().frame(width: 14, height: 14)
                            Circle().stroke(lineWidth: 2).frame(width: 18, height: 18)
                        }
                        .accessibilityLabel(pin.title)
                    }
                }
                .onAppear {
                    loc.request()
                    if let coord = loc.lastLocation?.coordinate {
                        region.center = coord
                        region.span = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Controls
                HStack {
                    Toggle("Show My Location", isOn: $isShowingUser)
                    Spacer()
                    Button { centerOnUser() } label: { Label("Center on Me", systemImage: "location") }
                    Button(role: .destructive) { pins.removeAll() } label: { Label("Clear Pins", systemImage: "trash") }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Map Starter")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { dropPinAtCenter() } label: { Label("Drop Pin", systemImage: "mappin.and.ellipse") }
                }
            }
        }
    }

    // MARK: - Actions
    private func dropPinAtCenter() { addPin(title: "Center Pin", at: region.center) }

    private func centerOnUser() {
        if let coord = loc.lastLocation?.coordinate {
            withAnimation { region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)) }
        }
    }

    private func performSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        request.region = region
        MKLocalSearch(request: request).start { response, error in
            guard let first = response?.mapItems.first, error == nil else { return }
            let coord = first.placemark.coordinate
            addPin(title: first.name ?? q, at: coord)
            withAnimation { region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)) }
        }
    }

    private func addPin(title: String, at coord: CLLocationCoordinate2D) {
        withAnimation { pins.append(Pin(title: title, coordinate: coord)) }
    }
}

#Preview { ContentView() }

#else
// macOS placeholder so the project still compiles if you accidentally pick a Mac run destination.
import SwiftUI
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("This sample targets iOS.")
            Text("In Xcode, choose an iPhone simulator in the toolbar device menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
#Preview { ContentView() }
#endif

