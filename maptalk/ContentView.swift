#if os(iOS)
import SwiftUI
import MapKit
import CoreLocation
import Combine

// MARK: - Models（保留，为后续扩展
struct Pin: Identifiable, Hashable, Equatable {
    let id = UUID()
    var title: String
    var coordinate: CLLocationCoordinate2D
    static func == (lhs: Pin, rhs: Pin) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct RouteLine: Identifiable, Hashable, Equatable {
    let id = UUID()
    var coordinates: [CLLocationCoordinate2D]
    /// 霓虹配色使用索引，避免 Hashable 问题
    var colorIndex: Int
    static func == (lhs: RouteLine, rhs: RouteLine) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - NavigationModel（industry standard: MKDirections + off-route detection）
// [CHANGED]: extended with reroute logic
@MainActor
final class NavigationModel: ObservableObject {
    enum Mode { case automobile, walking, transit }

    @Published var destination: CLLocationCoordinate2D? = nil
    @Published var route: MKRoute? = nil
    @Published var routeCoordinates: [CLLocationCoordinate2D] = []
    @Published var etaText: String? = nil
    @Published var distanceText: String? = nil
    @Published var isComputing: Bool = false

    // [ADDED] Reroute configuration
    var mode: Mode = .automobile
    var offRouteToleranceMeters: CLLocationDistance = 45        // tweak 35–60m as you like
    var minRerouteInterval: TimeInterval = 8                     // throttle
    private var lastRerouteAt: Date? = nil

    private let formatter: MeasurementFormatter = {
        let f = MeasurementFormatter()
        f.unitOptions = .naturalScale
        f.unitStyle = .medium
        return f
    }()

    func setDestination(_ coord: CLLocationCoordinate2D) { destination = coord }

    func planRoute(from start: CLLocationCoordinate2D,
                   to end: CLLocationCoordinate2D,
                   mode: Mode = .automobile) {
        isComputing = true
        self.mode = mode
        self.destination = end

        let src = MKMapItem(placemark: MKPlacemark(coordinate: start))
        let dst = MKMapItem(placemark: MKPlacemark(coordinate: end))

        let req = MKDirections.Request()
        req.source = src
        req.destination = dst
        req.requestsAlternateRoutes = false
        switch mode {
        case .automobile: req.transportType = .automobile
        case .walking:    req.transportType = .walking
        case .transit:    req.transportType = .transit
        }

        MKDirections(request: req).calculate { [weak self] resp, err in
            guard let self = self else { return }
            self.isComputing = false
            guard err == nil, let best = resp?.routes.first else {
                self.route = nil
                self.routeCoordinates = []
                self.etaText = nil
                self.distanceText = nil
                return
            }
            self.route = best
            self.routeCoordinates = best.polyline.coordinates
            let mins = Int(ceil(best.expectedTravelTime / 60))
            self.etaText = "\(mins) min"
            let meas = Measurement(value: best.distance, unit: UnitLength.meters)
                .converted(to: .kilometers)
            self.distanceText = self.formatter.string(from: meas)
        }
    }

    // [ADDED] Call this on user location updates to auto-reroute when off path
    func considerReroute(current: CLLocationCoordinate2D) {
        guard let dest = destination,
              let _ = route,
              !isComputing else { return }

        // Throttle
        if let last = lastRerouteAt, Date().timeIntervalSince(last) < minRerouteInterval { return }

        // Off-route detection
        let distance = distanceToCurrentRouteMeters(from: current)
        if distance > offRouteToleranceMeters {
            lastRerouteAt = Date()
            planRoute(from: current, to: dest, mode: mode)
        }
    }

    // [ADDED] Compute shortest distance from point to current polyline (in meters)
    private func distanceToCurrentRouteMeters(from coord: CLLocationCoordinate2D) -> CLLocationDistance {
        guard routeCoordinates.count > 1 else { return .greatestFiniteMagnitude }
        let point = MKMapPoint(coord)
        var minMeters = CLLocationDistance.greatestFiniteMagnitude

        var prev = MKMapPoint(routeCoordinates[0])
        for c in routeCoordinates.dropFirst() {
            let next = MKMapPoint(c)
            let meters = point.distance(toSegmentFrom: prev, to: next)
            if meters < minMeters { minMeters = meters }
            prev = next
        }
        return minMeters
    }
}

// [ADDED] MKPolyline / helpers
private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

// [ADDED] MKMapPoint geometry helper: distance to segment
private extension MKMapPoint {
    func distance(toSegmentFrom a: MKMapPoint, to b: MKMapPoint) -> CLLocationDistance {
        let dx = b.x - a.x
        let dy = b.y - a.y
        if dx == 0 && dy == 0 { return self.distance(to: a) }

        // Project self onto segment ab
        let t = max(0, min(1, ((self.x - a.x) * dx + (self.y - a.y) * dy) / (dx*dx + dy*dy)))
        let proj = MKMapPoint(x: a.x + t*dx, y: a.y + t*dy)
        return self.distance(to: proj)
    }
}

// MARK: - Location Manager（启用）
@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var lastLocation: CLLocation? = nil
    private let manager = CLLocationManager()

    override init() {
        super.init()
        authorizationStatus = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func request() {
        if authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
    }
}

// MARK: - ContentView (Cyber Neon)
struct ContentView: View {
    @StateObject private var loc = LocationManager()
    @StateObject private var nav = NavigationModel()

    // 初始 Seattle
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )
    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
    )

    @State private var pins: [Pin] = []
    @State private var routes: [RouteLine] = []
    @State private var isShowingUser: Bool = true
    @State private var mapCenter: CLLocationCoordinate2D? = nil
    @State private var followEnabled = true

    private let routePalette: [Color] = [
        Color.cyan.opacity(0.95),
        Color.purple.opacity(0.95),
        Color.blue.opacity(0.95),
        Color.mint.opacity(0.95),
        Color.pink.opacity(0.95),
        Color.indigo.opacity(0.95)
    ]

    private let followDistance: CLLocationDistance = 1200

    var body: some View {
        NavigationStack {
            ZStack {
                MapReader { _ in
                    Map(position: $position) {
                        if isShowingUser { UserAnnotation() }
                        ForEach(routes) { r in
                            let c = routePalette[r.colorIndex % routePalette.count]
                            MapPolyline(coordinates: r.coordinates)
                                .stroke(c.opacity(0.55), style: StrokeStyle(lineWidth: 8))
                            MapPolyline(coordinates: r.coordinates)
                                .stroke(c, style: StrokeStyle(lineWidth: 3))
                        }
                    }
                    .onMapCameraChange(frequency: .continuous) { context in
                        mapCenter = context.region.center
                        region = context.region
                    }
                    .simultaneousGesture(DragGesture().onChanged { _ in followEnabled = false })
                    .simultaneousGesture(MagnificationGesture().onChanged { _ in followEnabled = false })
                    .simultaneousGesture(RotationGesture().onChanged { _ in followEnabled = false })
                }
                .ignoresSafeArea()
                .onAppear { loc.request() }

                // Follow camera + reroute check on location updates
                .onReceive(loc.$lastLocation.compactMap { $0?.coordinate }) { coord in
                    if followEnabled { followUser(to: coord) }
                    // [ADDED] Ask NavigationModel to reroute if off path
                    nav.considerReroute(current: coord)
                }

                // Render new route coords when computed
                .onReceive(nav.$routeCoordinates) { coords in
                    routes = coords.isEmpty ? [] : [RouteLine(coordinates: coords, colorIndex: 0)]
                }

                // —— HUD —— //
                VStack { Spacer() }
                    .background(
                        ZStack {
                            LinearGradient(colors: [Color.purple.opacity(0.22), Color.cyan.opacity(0.18)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                                .blendMode(.overlay)
                            Color.black.opacity(0.08).blendMode(.multiply)
                            RadialGradient(colors: [Color.clear, Color.black.opacity(0.18)],
                                           center: .center, startRadius: 40, endRadius: 600)
                        }
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("MapTalk – Neon").font(.headline)
                        if let eta = nav.etaText, let dist = nav.distanceText {
                            Text("· \(eta) • \(dist)").font(.caption).foregroundStyle(.secondary)
                        }
                        if nav.isComputing { ProgressView().scaleEffect(0.8) }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.top, 12)
                    .padding(.horizontal)
                    Spacer()
                }

                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        // 回到我
                        HUDButton(systemName: "location.fill", enabled: true) {
                            followEnabled = true
                            if let c = loc.lastLocation?.coordinate {
                                followUser(to: c)
                            } else {
                                loc.request()
                            }
                        }
                        // 规划：我 → 地图中心
                        HUDButton(systemName: "mappin.and.ellipse", enabled: true) {
                            guard let start = loc.lastLocation?.coordinate,
                                  let end = mapCenter else { return }
                            nav.setDestination(end)
                            nav.planRoute(from: start, to: end, mode: .automobile)
                            followEnabled = false
                        }
                        // 清除
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

    // MARK: - Camera Follow
    private func followUser(to coord: CLLocationCoordinate2D) {
        var cam = MapCamera(centerCoordinate: coord, distance: followDistance)
        cam.heading = 0
        cam.pitch = 0
        withAnimation(.easeInOut) {
            position = .camera(cam)
        }
    }
}

// MARK: - HUD / Pins / Overlay (unchanged)
private struct HUDButton: View {
    let systemName: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .padding(12)
        }
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.5)
    }
}

private struct NeonPin: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.22))
                .frame(width: 36, height: 36)
                .blur(radius: 6)
                .opacity(pulse ? 1 : 0.5)
                .scaleEffect(pulse ? 1.12 : 0.96)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .cyan.opacity(0.9), radius: 8)
                .shadow(color: .purple.opacity(0.6), radius: 16)
        }
        .onAppear { pulse = true }
    }
}

// 备用 Overlay（未用）
private struct RouteOverlay: View {
    var region: MKCoordinateRegion
    var routes: [RouteLine]
    var palette: [Color]

    var body: some View {
        GeometryReader { _ in
            Canvas { ctx, size in
                for route in routes {
                    guard route.coordinates.count > 1 else { continue }
                    let path = Path { p in
                        if let first = route.coordinates.first {
                            p.move(to: CGPoint(x: 0, y: 0))
                            p.addLine(to: CGPoint(x: 1, y: 1))
                        }
                    }
                }
            }
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
