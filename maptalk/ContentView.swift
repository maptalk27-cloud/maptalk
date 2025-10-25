// SwiftUI Map – Cyber Neon Multi‑Route (iOS 17+, Xcode 15)
// Theme: 蓝紫霓虹风（Four Seasons 夜景 + 赛博 HUD）
// 功能：固定坐标多 Pin、从当前位置 → 每个 Pin 多条路线、清空、居中
// 使用：把此文件内容替换到 ContentView.swift。Info.plist 需有 NSLocationWhenInUseUsageDescription。

#if os(iOS)
import SwiftUI
import MapKit
import CoreLocation
import Combine

// MARK: - Models
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
    /// Use palette index instead of `Color` to avoid Hashable issues
    var colorIndex: Int
    static func == (lhs: RouteLine, rhs: RouteLine) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Location Manager
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

    // 地图相机
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )

    // 固定坐标（示例：请替换为你的坐标集）
    // 例：Seattle 周边几个点
    private let fixedDestinations: [Pin] = [
        Pin(title: "Kerry Park", coordinate: .init(latitude: 47.6295, longitude: -122.3590)),
        Pin(title: "Gas Works Park", coordinate: .init(latitude: 47.6456, longitude: -122.3344)),
        Pin(title: "Alki Beach", coordinate: .init(latitude: 47.5817, longitude: -122.4058)),
        Pin(title: "Bellevue Downtown", coordinate: .init(latitude: 47.6149, longitude: -122.1936))
    ]

    // 运行时状态
    @State private var pins: [Pin] = []
    @State private var routes: [RouteLine] = []
    @State private var isShowingUser: Bool = true

    // 路线配色（蓝紫霓虹）
    private let routePalette: [Color] = [
        Color.cyan.opacity(0.95),
        Color.purple.opacity(0.95),
        Color.blue.opacity(0.95),
        Color.mint.opacity(0.95),
        Color.pink.opacity(0.95),
        Color.indigo.opacity(0.95)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                // 底层地图
                Map(
                    coordinateRegion: $region,
                    interactionModes: .all,
                    showsUserLocation: isShowingUser,
                    annotationItems: pins
                ) { pin in
                    MapAnnotation(coordinate: pin.coordinate) {
                        NeonPin()
                            .accessibilityLabel(pin.title)
                    }
                }
                // 叠加多段路线
                .overlay {
                    // SwiftUI 的 Map 也支持多段 polyline；这里我们用 overlay + Map-like 绘制
                    // 用 Canvas 将路线以 Path 形式绘制在屏幕投影坐标上更灵活；
                    // 但为简洁，使用 MapPolyline 等新 API 也可（iOS17 有 MapPolyline，但这里用自绘避免 API 差异）。
                    RouteOverlay(region: region, routes: routes, palette: routePalette)
                        .allowsHitTesting(false)
                }
                .onAppear { centerOnUserIfAvailable() }
                .ignoresSafeArea()

                // —— 赛博霓虹滤镜层（蓝紫冷光 + 轻微压黑 + 暗角）——
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

                // 顶部 HUD（标题 + 说明）
                VStack(spacing: 8) {
                    Text("MapTalk – Neon")
                        .font(.headline)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(radius: 6)
                        .padding(.top, 12)
                        .padding(.horizontal)
                    Spacer()
                }

                // 右下角悬浮控制
                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        HUDButton(systemName: "location.fill") { centerOnUserIfAvailable() }
                        HUDButton(systemName: "mappin.and.ellipse") { dropFixedPinsAndRoutes() }
                        HUDButton(systemName: "trash") { clearAll() }
                    }
                    .padding(.trailing)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .navigationBarHidden(true)
        }
    }

    // MARK: - Actions
    private func centerOnUserIfAvailable() {
        loc.request()
        if let coord = loc.lastLocation?.coordinate {
            withAnimation(.easeInOut) {
                region.center = coord
                region.span = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            }
        }
    }

    private func dropFixedPinsAndRoutes() {
        pins = fixedDestinations
        routes.removeAll()

        let start = loc.lastLocation?.coordinate ?? region.center   // fallback
        buildRoutes(from: start, to: pins.map { $0.coordinate })
    }

    private func clearAll() {
        withAnimation { pins.removeAll(); routes.removeAll() }
    }

    private func buildRoutes(from start: CLLocationCoordinate2D, to destinations: [CLLocationCoordinate2D]) {
        for (idx, dest) in destinations.enumerated() {
            var request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
            request.transportType = .automobile
            request.requestsAlternateRoutes = false

            MKDirections(request: request).calculate { response, error in
                guard let route = response?.routes.first, error == nil else { return }
                let coordsPtr = route.polyline.points()
                let count = route.polyline.pointCount
                var coords = [CLLocationCoordinate2D](repeating: .init(), count: count)
                for i in 0..<count { coords[i] = coordsPtr[i].coordinate }

                // 颜色循环
                let color = routePalette[idx % routePalette.count]
                withAnimation(.easeInOut) {
                    routes.append(RouteLine(coordinates: coords, colorIndex: idx % routePalette.count))
                }

                // 自动缩放以包含更多路线（可选：这里只在第一条返回时缩放）
                if idx == 0 {
                    let box = route.polyline.boundingMapRect
                    let reg = MKCoordinateRegion(box)
                    withAnimation(.easeInOut) { region = reg }
                }
            }
        }
    }
}

// MARK: - HUD / Pins / Overlay
private struct HUDButton: View {
    let systemName: String
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

// 将路线投影并绘制为矢量路径的 Overlay（简洁实现）
private struct RouteOverlay: View {
    var region: MKCoordinateRegion
    var routes: [RouteLine]
    var palette: [Color]          // ← add this

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                for route in routes {
                    guard route.coordinates.count > 1 else { continue }
                    let path = Path { p in
                        if let first = route.coordinates.first {
                            p.move(to: point(for: first, in: size))
                            for coord in route.coordinates.dropFirst() {
                                p.addLine(to: point(for: coord, in: size))
                            }
                        }
                    }
                    let col = palette[route.colorIndex % max(palette.count, 1)]
                    ctx.stroke(path, with: .color(col.opacity(0.55)), lineWidth: 8)
                    ctx.stroke(path, with: .color(col), lineWidth: 3)
                }
            }
        }
    }

    // 将经纬度转换到当前可视区域的屏幕坐标（近似投影）
    private func point(for coordinate: CLLocationCoordinate2D, in size: CGSize) -> CGPoint {
        // 简化投影（适合中小尺度，本场景足够）
        let span = region.span
        let center = region.center
        let x = (coordinate.longitude - (center.longitude - span.longitudeDelta/2)) / span.longitudeDelta
        let y = 1 - (coordinate.latitude - (center.latitude - span.latitudeDelta/2)) / span.latitudeDelta
        return CGPoint(x: x * size.width, y: y * size.height)
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
