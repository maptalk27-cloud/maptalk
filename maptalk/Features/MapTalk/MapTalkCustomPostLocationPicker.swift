import CoreLocation
import MapKit
import SwiftUI

/// A Post can describe any nearby point. This does not create a landmark or
/// change the current GPS location used by POI check-ins.
struct MapTalkCustomPostLocationPicker: View {
    let origin: CLLocation
    let onSelect: (MapTalkPostLocationSelection) -> Void
    let onBack: () -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var selectedCoordinate: CLLocationCoordinate2D
    @State private var visibleRegion: MKCoordinateRegion
    @State private var name: String
    @State private var isCameraSettled = false
    @FocusState private var isNaming: Bool

    init(origin: CLLocation, selection: MapTalkPostLocationSelection?,
         onSelect: @escaping (MapTalkPostLocationSelection) -> Void,
         onBack: @escaping () -> Void) {
        self.origin = origin
        self.onSelect = onSelect
        self.onBack = onBack
        let coordinate = selection?.coordinate ?? origin.coordinate
        let offset = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: origin)
        // Keep both the chosen point and its allowed circle visible initially.
        // Later GPS updates move the circle, never the person's chosen pin.
        let extent = (PostLocationPolicy.radius + min(offset, PostLocationPolicy.radius)) * 2.2
        let region = MKCoordinateRegion(center: coordinate,
                                        latitudinalMeters: extent,
                                        longitudinalMeters: extent)
        _cameraPosition = State(initialValue: .region(region))
        _visibleRegion = State(initialValue: region)
        _selectedCoordinate = State(initialValue: coordinate)
        let initialName = selection?.locationName
            ?? (selection?.title == "Previous post location" ? "" : selection?.title ?? "")
        _name = State(initialValue: initialName)
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isWithinRange: Bool {
        PostLocationPolicy.location(for: .init(coordinate: selectedCoordinate, title: cleanName),
                                    near: origin) != nil
    }

    private var canSave: Bool {
        isCameraSettled && isWithinRange && PostLocationPolicy.normalizedName(name) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            map
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16)
                .padding(.top, 8)

            namingControls
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
        }
        .padding(.top, 6)
        .background(Color.white.ignoresSafeArea())
        .environment(\.colorScheme, .light)
        .accessibilityIdentifier("maptalk.post.custom-location")
    }

    private var header: some View {
        PublishLocationPickerHeader(title: "Create new", backLabel: "Back to locations",
            backIdentifier: "maptalk.post.custom-location-back") {
                isNaming = false
                onBack()
            }
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                MapCircle(center: origin.coordinate, radius: PostLocationPolicy.radius)
                    .foregroundStyle(Color.teal.opacity(0.07))
                    .stroke(Color.teal.opacity(0.5), lineWidth: 1.5)
                Annotation("You are here", coordinate: origin.coordinate) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                        .allowsHitTesting(false)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControlVisibility(.hidden)
            .onMapCameraChange(frequency: .continuous) { context in
                selectedCoordinate = context.region.center
                isCameraSettled = false
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                selectedCoordinate = context.region.center
                visibleRegion = context.region
                isCameraSettled = true
            }
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                guard let coordinate = proxy.convert(tap.location, from: .local) else { return }
                movePin(to: coordinate)
            })
            .overlay {
                Image(systemName: "mappin")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(isWithinRange ? Color.black : Color.red)
                    .shadow(color: .white.opacity(0.9), radius: 2)
                    .offset(y: -18)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .top) {
                Text("Move the map to place your pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.68))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    movePin(to: origin.coordinate)
                } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .accessibilityLabel("Return to current location")
            }
            .accessibilityIdentifier("maptalk.post.custom-location-map")
        }
    }

    private func movePin(to coordinate: CLLocationCoordinate2D) {
        isNaming = false
        // An unchanged camera need not emit onEnd. Don't lock confirmation
        // when the person taps recenter at the point already under the pin.
        let distance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: selectedCoordinate.latitude, longitude: selectedCoordinate.longitude))
        guard distance > 0.1 else { return }
        isCameraSettled = false
        withAnimation(.easeOut(duration: 0.2)) {
            cameraPosition = .region(.init(center: coordinate, span: visibleRegion.span))
        }
    }

    private var namingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name this location", text: $name)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(Color.black.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 12))
                .focused($isNaming)
                .submitLabel(.done)
                .onSubmit { isNaming = false }
                .accessibilityIdentifier("maptalk.post.custom-location-name")

            Text(!isWithinRange ? "Choose a point within 5 km"
                 : cleanName.utf16.count > 80 ? "Name is too long (80 max)"
                 : !cleanName.isEmpty && PostLocationPolicy.normalizedName(name) == nil ? "Use a single-line name"
                 : "Anywhere within 5 km of you")
                .font(.system(size: 12))
                .foregroundStyle(isWithinRange && (cleanName.isEmpty || PostLocationPolicy.normalizedName(name) != nil)
                                 ? Color.black.opacity(0.45) : .red)
                .accessibilityIdentifier("maptalk.post.custom-location-range")

            Button {
                guard canSave else { return }
                isNaming = false
                onSelect(.init(coordinate: selectedCoordinate, title: cleanName, locationName: cleanName))
            } label: {
                Text("Use this place")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(canSave ? Color.black : Color.black.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityIdentifier("maptalk.post.custom-location-use")
        }
    }
}
