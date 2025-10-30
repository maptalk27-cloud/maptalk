import MapKit
import SwiftUI

struct RouteMapView: View {
    @Binding var position: MapCameraPosition
    let routes: [RouteLine]
    var showUser: Bool = true
    var onCameraChange: (MKCoordinateRegion) -> Void = { _ in }
    var onUserInteraction: () -> Void = {}

    var body: some View {
        MapReader { _ in
            Map(position: $position) {
                if showUser {
                    UserAnnotation()
                }
                ForEach(routes) { route in
                    let color = route.colorIndex % RoutePalette.colors.count
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(RoutePalette.colors[color].opacity(0.55), style: StrokeStyle(lineWidth: 8))
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(RoutePalette.colors[color], style: StrokeStyle(lineWidth: 3))
                }
            }
            .onMapCameraChange(frequency: .continuous) { context in
                onCameraChange(context.region)
            }
            .simultaneousGesture(
                DragGesture().onChanged { _ in onUserInteraction() }
            )
            .simultaneousGesture(
                MagnificationGesture().onChanged { _ in onUserInteraction() }
            )
            .simultaneousGesture(
                RotationGesture().onChanged { _ in onUserInteraction() }
            )
        }
        .ignoresSafeArea()
    }
}

private enum RoutePalette {
    static let colors: [Color] = [
        Color.cyan.opacity(0.95),
        Color.purple.opacity(0.95),
        Color.blue.opacity(0.95),
        Color.mint.opacity(0.95),
        Color.pink.opacity(0.95),
        Color.indigo.opacity(0.95)
    ]
}

#Preview {
    RouteMapView(
        position: .constant(.region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ))),
        routes: [
            RouteLine(
                coordinates: [
                    CLLocationCoordinate2D(latitude: 47.60, longitude: -122.34),
                    CLLocationCoordinate2D(latitude: 47.62, longitude: -122.32)
                ],
                colorIndex: 0
            )
        ]
    )
}
