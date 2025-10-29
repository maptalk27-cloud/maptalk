// SwiftUI Map – Cyber Neon (Follow-User On)  iOS 17+, Xcode 15
// 保留 UI/霓虹主题 + 启用定位与持续跟随用户位置。
// Info.plist 需含 NSLocationWhenInUseUsageDescription

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
        manager.distanceFilter = 5 // 米：位置变化 5m 才回调，避免过于频繁
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

    // 初始给个城市级范围，拿到定位后自动切换为 camera 跟随
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

    // 运行时状态（当前不渲染 pin/route，仅保留接口）
    @State private var pins: [Pin] = []
    @State private var routes: [RouteLine] = []
    @State private var isShowingUser: Bool = true     // 显示系统用户点
    @State private var mapCenter: CLLocationCoordinate2D? = nil
    @State private var followEnabled = true

    // —— 霓虹路线配色（之后用于导航渲染）——
    private let routePalette: [Color] = [
        Color.cyan.opacity(0.95),
        Color.purple.opacity(0.95),
        Color.blue.opacity(0.95),
        Color.mint.opacity(0.95),
        Color.pink.opacity(0.95),
        Color.indigo.opacity(0.95)
    ]

    // 跟随参数
    private let followDistance: CLLocationDistance = 1200 // 相机距地面高度（米），可按需调整

    var body: some View {
        NavigationStack {
            ZStack {
                // 底层地图
                MapReader { _ in
                    Map(position: $position) {
                        if isShowingUser { UserAnnotation() }

                        // 预留（不渲染）
                        // ForEach(pins) { pin in
                        //     Annotation(pin.title, coordinate: pin.coordinate) { NeonPin() }
                        // }
                        // ForEach(routes) { r in
                        //     let c = routePalette[r.colorIndex % routePalette.count]
                        //     MapPolyline(coordinates: r.coordinates)
                        //         .stroke(c.opacity(0.55), style: StrokeStyle(lineWidth: 8))
                        //     MapPolyline(coordinates: r.coordinates)
                        //         .stroke(c, style: StrokeStyle(lineWidth: 3))
                        // }
                    }
                    .onMapCameraChange(frequency: .continuous) { context in
                        mapCenter = context.region.center
                        region = context.region
                    }
                }
                .ignoresSafeArea()
                .onAppear {
                    // 请求权限 & 启动定位
                    loc.request()
                }
                // 使用发布者响应位置变化（避免 onChange 的 Equatable 限制）
                .onReceive(loc.$lastLocation.compactMap { $0?.coordinate }) { coord in
                    followUser(to: coord)
                }

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

                // 顶部 HUD（标题）
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
                        // 恢复第一个按钮为“回到我”
                        HUDButton(systemName: "location.fill", enabled: true) {
                            if let c = loc.lastLocation?.coordinate {
                                followUser(to: c)
                            } else {
                                loc.request()
                            }
                        }
                        // 其余两个保持 UI，无行为（no-op）
                        HUDButton(systemName: "mappin.and.ellipse", enabled: false) { /* no-op */ }
                        HUDButton(systemName: "trash", enabled: false) { /* no-op */ }
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

// MARK: - HUD / Pins / Overlay
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

// 将路线投影并绘制为矢量路径的 Overlay（保留，但当前不使用）
private struct RouteOverlay: View {
    var region: MKCoordinateRegion
    var routes: [RouteLine]
    var palette: [Color]

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

    private func point(for coordinate: CLLocationCoordinate2D, in size: CGSize) -> CGPoint {
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
