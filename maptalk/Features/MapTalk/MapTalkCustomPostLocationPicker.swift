import CoreLocation
import MapKit
import SwiftUI

/// Post subject locations are separate from the current-GPS POI check-in rules.
/// Only authored POI visits expand the shaded area; old Posts remain reusable
/// points, and never grant permission to place a new pin around them.
struct MapTalkCustomPostLocationPicker: View {
    let library: MapTalkPostLocationLibrary
    let origin: CLLocation?
    let onSelect: (MapTalkPostLocationSelection) -> Void
    let onBack: () -> Void

    @State private var cameraRequest: PostLocationCameraRequest
    @State private var selectedCoordinate: CLLocationCoordinate2D
    @State private var visibleRegion: MKCoordinateRegion
    @State private var name: String
    @State private var selectedHistory: MapTalkPostLocationChoice?
    @State private var locationID = UUID()
    @State private var originalSelection: MapTalkPostLocationSelection?
    @State private var isCameraSettled = false
    @State private var isShowingRegions = false
    @FocusState private var isNaming: Bool

    init(library: MapTalkPostLocationLibrary, origin: CLLocation?, selection: MapTalkPostLocationSelection?,
         onSelect: @escaping (MapTalkPostLocationSelection) -> Void,
         onBack: @escaping () -> Void) {
        self.library = library
        self.origin = origin
        self.onSelect = onSelect
        self.onBack = onBack
        _originalSelection = State(initialValue: selection)
        let coordinate = selection?.coordinate ?? origin?.coordinate
            ?? library.coverage.areas.first?.coordinate
            ?? library.choices.first?.selection.coordinate
            ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let region = Self.region(around: coordinate)
        _cameraRequest = State(initialValue: .init(region: region))
        _visibleRegion = State(initialValue: region)
        _selectedCoordinate = State(initialValue: coordinate)
        _name = State(initialValue: selection.map { Self.editableName($0) } ?? "")
        _selectedHistory = State(initialValue: library.choices.first { choice in
            guard let selection else { return false }
            return choice.selection.locationID == selection.locationID
                && choice.selection.coordinate.latitude == selection.coordinate.latitude
                && choice.selection.coordinate.longitude == selection.coordinate.longitude
                && choice.selection.locationName == selection.locationName
        })
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var unchangedSelection: MapTalkPostLocationSelection? {
        guard let originalSelection,
              abs(originalSelection.coordinate.latitude - selectedCoordinate.latitude) < 0.000001,
              abs(originalSelection.coordinate.longitude - selectedCoordinate.longitude) < 0.000001,
              Self.editableName(originalSelection) == cleanName,
              library.location(for: originalSelection, currentLocation: origin) != nil else { return nil }
        return originalSelection
    }

    private var isWithinRange: Bool {
        library.coverage.contains(selectedCoordinate, currentLocation: origin)
    }

    private var canSave: Bool {
        if let selectedHistory {
            return library.location(for: selectedHistory.selection, currentLocation: origin) != nil
        }
        return isCameraSettled && (unchangedSelection != nil
            || (isWithinRange && PostLocationPolicy.normalizedName(name) != nil))
    }

    var body: some View {
        VStack(spacing: 0) {
            PublishLocationPickerHeader(title: "Create new", backLabel: "Back to locations",
                backIdentifier: "maptalk.post.custom-location-back") {
                    isNaming = false
                    onBack()
                }

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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maptalk.post.custom-location")
        .sheet(isPresented: $isShowingRegions) {
            PostLocationRegionSheet(regions: library.regions) { region in
                isShowingRegions = false
                clearHistorySelection()
                isNaming = false
                isCameraSettled = false
                cameraRequest = .init(region: region.mapRegion)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChangeCompat(of: library.revision) { _ in
            if let selectedHistory {
                guard library.location(for: selectedHistory.selection, currentLocation: origin) != nil,
                      let updated = library.choices.first(where: { $0.id == selectedHistory.id }) else {
                    clearHistorySelection()
                    return
                }
                // A sync may change a location's newest representative. Do not
                // silently move or rename the pin the person is confirming.
                if updated.selection.locationID == selectedHistory.selection.locationID,
                   updated.selection.coordinate.latitude == selectedHistory.selection.coordinate.latitude,
                   updated.selection.coordinate.longitude == selectedHistory.selection.coordinate.longitude,
                   updated.selection.locationName == selectedHistory.selection.locationName {
                    self.selectedHistory = updated
                }
            }
        }
    }

    private var map: some View {
        PostLocationMap(library: library, origin: origin, cameraRequest: cameraRequest,
            selectedHistoryID: selectedHistory?.id,
            onCameraMoving: { isCameraSettled = false },
            onCameraSettled: { region in
                if selectedHistory == nil { selectedCoordinate = region.center }
                visibleRegion = region
                isCameraSettled = true
            },
            onTap: { movePin(to: $0) },
            onSelectHistory: { choice in
                guard library.location(for: choice.selection, currentLocation: origin) != nil else { return }
                isNaming = false
                selectedHistory = choice
                selectedCoordinate = choice.selection.coordinate
                name = Self.editableName(choice.selection)
            })
            .overlay {
                if selectedHistory == nil {
                    Image(systemName: "mappin")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(!isCameraSettled ? Color.gray
                                         : isWithinRange || unchangedSelection != nil ? .black : .red)
                        .shadow(color: .white.opacity(0.9), radius: 2)
                        .offset(y: -18)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .top) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 0.23, green: 0.52, blue: 0.44))
                        .frame(width: 7, height: 7)
                    Text("Your areas · 5 km")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.68))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 12)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                if !library.regions.isEmpty {
                    Button {
                        isNaming = false
                        isShowingRegions = true
                    } label: {
                        Label("Regions", systemImage: "globe.americas")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .accessibilityIdentifier("maptalk.post.custom-location-regions")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let origin {
                    Button { movePin(to: origin.coordinate, resetZoom: true) } label: {
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
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("maptalk.post.custom-location-map")
    }

    private func movePin(to coordinate: CLLocationCoordinate2D, resetZoom: Bool = false) {
        isNaming = false
        clearHistorySelection()
        let distance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: selectedCoordinate.latitude, longitude: selectedCoordinate.longitude))
        guard distance > 0.1 || resetZoom else { return }
        isCameraSettled = false
        cameraRequest = .init(region: resetZoom ? Self.region(around: coordinate)
                             : .init(center: coordinate, span: visibleRegion.span))
    }

    private func clearHistorySelection() {
        guard selectedHistory != nil else { return }
        selectedHistory = nil
        originalSelection = nil
        name = ""
        locationID = UUID()
        selectedCoordinate = visibleRegion.center
    }

    private var namingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selectedHistory {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(MapTalkPostLocationPicker.displayTitle(for: selectedHistory))
                            .font(.system(size: 17, weight: .medium))
                            .lineLimit(1)
                        Text("\(selectedHistory.postCount) \(selectedHistory.postCount == 1 ? "post" : "posts") here")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("New pin") { clearHistorySelection() }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("maptalk.post.custom-location-clear-selection")
                }
                .padding(.horizontal, 14)
                .frame(height: 52)
                .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("maptalk.post.custom-location-selected")
            } else {
                TextField("Name this location", text: $name)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    .focused($isNaming)
                    .submitLabel(.done)
                    .onSubmit { isNaming = false }
                    .accessibilityIdentifier("maptalk.post.custom-location-name")
            }

            Text(selectedHistory != nil ? "Use this place to add another Post"
                 : !isCameraSettled ? "Move the map to choose a point"
                 : !isWithinRange && unchangedSelection == nil ? "Choose a point in the mint area"
                 : cleanName.utf16.count > 80 ? "Name is too long (80 max)"
                 : !cleanName.isEmpty && PostLocationPolicy.normalizedName(name) == nil ? "Use a single-line name"
                 : !isWithinRange ? "Reuse your existing Post location"
                 : "Within 5 km of you or a POI you've visited")
                .font(.system(size: 12))
                .foregroundStyle(selectedHistory == nil && (isCameraSettled && !isWithinRange && unchangedSelection == nil
                                 || (!cleanName.isEmpty && PostLocationPolicy.normalizedName(name) == nil)
                                 )
                                 ? .red : Color.black.opacity(0.45))
                .accessibilityIdentifier("maptalk.post.custom-location-range")

            Button {
                guard canSave else { return }
                isNaming = false
                if let selectedHistory {
                    onSelect(selectedHistory.selection)
                } else if let unchangedSelection {
                    onSelect(unchangedSelection)
                } else {
                    onSelect(.init(coordinate: selectedCoordinate, title: cleanName,
                                   locationName: cleanName, locationID: locationID))
                }
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

    private static func editableName(_ selection: MapTalkPostLocationSelection) -> String {
        selection.locationName ?? (selection.title == "Previous post location" ? "" : selection.title)
    }

    private static func region(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        .init(center: coordinate, latitudinalMeters: PostLocationPolicy.radius * 2.2,
              longitudinalMeters: PostLocationPolicy.radius * 2.2)
    }
}

/// A short area switcher, not a second list of every visit or Post pin.
private struct PostLocationRegionSheet: View {
    let regions: [PostLocationRegion]
    let onJump: (PostLocationRegion) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var names = PostLocationRegionNameResolver.shared

    var body: some View {
        VStack(spacing: 0) {
            PublishLocationPickerHeader(title: "Regions", backLabel: "Back to map",
                backIdentifier: "maptalk.post.custom-location-regions-back") { dismiss() }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(regions) { region in
                        Button { onJump(region) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "globe.americas")
                                    .font(.system(size: 19, weight: .regular))
                                    .foregroundStyle(Color(red: 0.17, green: 0.49, blue: 0.38))
                                    .frame(width: 28)
                                Text(names.title(for: region))
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.black)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 60)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("maptalk.post.region.\(region.id)")
                        .onAppear { names.resolve(region) }
                        PublishLocationDivider()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .padding(.top, 10)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

private struct PostLocationCameraRequest {
    let id = UUID()
    let region: MKCoordinateRegion
}

/// Native MapKit keeps panning off SwiftUI's update path. The personal-history
/// snapshot changes annotations once, and coverage changes the cached overlay
/// once; a camera frame never regroups posts or scans visit records.
private struct PostLocationMap: UIViewRepresentable {
    let library: MapTalkPostLocationLibrary
    let origin: CLLocation?
    let cameraRequest: PostLocationCameraRequest
    let selectedHistoryID: String?
    let onCameraMoving: () -> Void
    let onCameraSettled: (MKCoordinateRegion) -> Void
    let onTap: (CLLocationCoordinate2D) -> Void
    let onSelectHistory: (MapTalkPostLocationChoice) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.pointOfInterestFilter = .excludingAll
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updateHistory(in: map)
        coordinator.updateSelection(in: map)
        coordinator.updateCoverage(in: map)
        if coordinator.cameraID != cameraRequest.id {
            let isInitial = coordinator.cameraID == nil
            coordinator.cameraID = cameraRequest.id
            let unchanged = abs(map.region.center.latitude - cameraRequest.region.center.latitude) < 0.000001
                && abs(map.region.center.longitude - cameraRequest.region.center.longitude) < 0.000001
                && abs(map.region.span.latitudeDelta - cameraRequest.region.span.latitudeDelta) < 0.000001
                && abs(map.region.span.longitudeDelta - cameraRequest.region.span.longitudeDelta) < 0.000001
            map.setRegion(cameraRequest.region, animated: !isInitial)
            if isInitial || unchanged {
                // Initial layout need not emit regionDidChange when MapKit
                // already has the requested region.
                DispatchQueue.main.async { [weak coordinator, weak map] in
                    guard let coordinator, let map else { return }
                    coordinator.parent.onCameraSettled(map.region)
                }
            }
        }
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) { map.delegate = nil }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: PostLocationMap
        weak var map: MKMapView?
        var cameraID: UUID?
        private var historyRevision: UUID?
        private var coverageRevision: UUID?
        private var originCoordinate: CLLocationCoordinate2D?
        private var historyAnnotations: [PostLocationHistoryAnnotation] = []
        private var coverageGeometry: PostLocationCoverageGeometry?
        private var coverageOverlay: PostLocationCoverageOverlay?
        private var currentAnnotation: MKPointAnnotation?
        private var selectedHistoryID: String?

        init(parent: PostLocationMap) { self.parent = parent }

        func updateHistory(in map: MKMapView) {
            guard historyRevision != parent.library.revision else { return }
            historyRevision = parent.library.revision
            map.removeAnnotations(historyAnnotations)
            historyAnnotations = parent.library.choices.map { PostLocationHistoryAnnotation(choice: $0) }
            map.addAnnotations(historyAnnotations)
        }

        func updateSelection(in map: MKMapView) {
            guard selectedHistoryID != parent.selectedHistoryID else { return }
            let previousID = selectedHistoryID
            selectedHistoryID = parent.selectedHistoryID
            for annotation in historyAnnotations where annotation.choice.id == previousID
                || annotation.choice.id == selectedHistoryID {
                (map.view(for: annotation) as? PostLocationThumbnailAnnotationView)?
                    .configure(choice: annotation.choice, selected: annotation.choice.id == selectedHistoryID)
            }
        }

        func updateCoverage(in map: MKMapView) {
            let coordinate = parent.origin?.coordinate
            let sameOrigin = coordinate?.latitude == originCoordinate?.latitude
                && coordinate?.longitude == originCoordinate?.longitude
            guard coverageRevision != parent.library.coverage.revision || !sameOrigin else { return }
            if coverageRevision != parent.library.coverage.revision {
                // Compile visited circles once per semantic history change.
                // A GPS fix changes just its own circle, not all historical geometry.
                coverageGeometry = .init(centers: parent.library.coverage.areas.map(\.coordinate),
                                         radius: PostLocationPolicy.radius)
            }
            coverageRevision = parent.library.coverage.revision
            originCoordinate = coordinate
            if let coverageOverlay { map.removeOverlay(coverageOverlay) }
            guard let coverageGeometry else { return }
            let overlay = PostLocationCoverageOverlay(history: coverageGeometry,
                currentCircle: coordinate.map { MKCircle(center: $0, radius: PostLocationPolicy.radius).boundingMapRect })
            coverageOverlay = overlay
            if !coverageGeometry.path.isEmpty || coordinate != nil { map.addOverlay(overlay, level: .aboveRoads) }
            if let coordinate, let currentAnnotation {
                currentAnnotation.coordinate = coordinate
            } else if let coordinate {
                let annotation = MKPointAnnotation()
                annotation.coordinate = coordinate
                annotation.title = "You are here"
                currentAnnotation = annotation
                map.addAnnotation(annotation)
            } else if let currentAnnotation {
                map.removeAnnotation(currentAnnotation)
                self.currentAnnotation = nil
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            DispatchQueue.main.async { [weak self] in self?.parent.onCameraMoving() }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            DispatchQueue.main.async { [weak self] in self?.parent.onCameraSettled(region) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard overlay is PostLocationCoverageOverlay else { return MKOverlayRenderer(overlay: overlay) }
            return PostLocationCoverageRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let history = annotation as? PostLocationHistoryAnnotation else {
                guard annotation === currentAnnotation else { return nil }
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "post-origin")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "post-origin")
                view.annotation = annotation
                view.frame.size = .init(width: 14, height: 14)
                view.backgroundColor = .systemBlue
                view.layer.cornerRadius = 7
                view.layer.borderWidth = 2
                view.layer.borderColor = UIColor.white.cgColor
                view.isEnabled = false
                view.accessibilityLabel = "You are here"
                return view
            }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "post-history-photo") as? PostLocationThumbnailAnnotationView
                ?? PostLocationThumbnailAnnotationView(annotation: history, reuseIdentifier: "post-history-photo")
            view.annotation = history
            view.configure(choice: history.choice, selected: history.choice.id == parent.selectedHistoryID)
            view.onTap = { [weak self] in self?.parent.onSelectHistory(history.choice) }
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let history = annotation as? PostLocationHistoryAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            parent.onSelectHistory(history.choice)
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map else { return }
            parent.onTap(map.convert(recognizer.location(in: map), toCoordinateFrom: map))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                // A history marker is a reuse action, not a new arbitrary pin.
                if current is MKAnnotationView || current is UIControl { return false }
                view = current.superview
            }
            return true
        }
    }
}

private final class PostLocationHistoryAnnotation: NSObject, MKAnnotation {
    let choice: MapTalkPostLocationChoice
    nonisolated let coordinate: CLLocationCoordinate2D
    nonisolated let title: String?

    init(choice: MapTalkPostLocationChoice) {
        self.choice = choice
        coordinate = choice.selection.coordinate
        // The thumbnail view owns its label; suppress MapKit's second title.
        title = nil
    }
}

/// Immutable map-point geometry shared across GPS-only overlay revisions. No
/// actor-isolated model state is touched by MapKit's background renderer.
private nonisolated final class PostLocationCoverageGeometry {
    let path: CGPath

    init(centers: [CLLocationCoordinate2D], radius: CLLocationDistance) {
        let combined = CGMutablePath()
        for center in centers {
            let circle = MKCircle(center: center, radius: radius).boundingMapRect
            Self.addCircle(circle, to: combined)
        }
        // Resolve overlaps in one pass so only the area's outer boundary is
        // stroked. Cache it with history, not with camera frames or GPS fixes.
        path = combined.normalized(using: .winding)
    }

    static func addCircle(_ circle: MKMapRect, to path: CGMutablePath) {
        path.addEllipse(in: .init(x: circle.minX, y: circle.minY,
                                 width: circle.size.width, height: circle.size.height))
        // Preserve a continuous 5 km disk at the date line without connecting
        // unrelated regions across the map.
        if circle.minX < MKMapRect.world.minX {
            path.addEllipse(in: .init(x: circle.minX + MKMapRect.world.size.width, y: circle.minY,
                                     width: circle.size.width, height: circle.size.height))
        } else if circle.maxX > MKMapRect.world.maxX {
            path.addEllipse(in: .init(x: circle.minX - MKMapRect.world.size.width, y: circle.minY,
                                     width: circle.size.width, height: circle.size.height))
        }
    }
}

private nonisolated final class PostLocationCoverageOverlay: NSObject, MKOverlay {
    let path: CGPath
    // A stable frame permits reuse of immutable historical path coordinates
    // even when a live GPS fix moves between far-away regions.
    let boundingMapRect = MKMapRect.world
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)

    init(history: PostLocationCoverageGeometry, currentCircle: MKMapRect?) {
        if let currentCircle {
            let current = CGMutablePath()
            PostLocationCoverageGeometry.addCircle(currentCircle, to: current)
            // Union the live disk with the cached history only when GPS changes.
            // Separate cities stay separate, and overlapping visits have no seams.
            path = history.path.isEmpty ? current.normalized(using: .winding) : history.path.union(current)
        } else {
            path = history.path
        }
    }
}

private nonisolated final class PostLocationCoverageRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let coverage = overlay as? PostLocationCoverageOverlay else { return }
        // MKOverlayRenderer points differ from world map points only by their
        // overlay-local origin; convert the cached union path in one step.
        let origin = point(for: MKMapPoint(x: 0, y: 0))
        var transform = CGAffineTransform(translationX: origin.x, y: origin.y)
        guard let path = coverage.path.copy(using: &transform) else { return }
        context.saveGState()
        context.clip(to: rect(for: mapRect))
        context.setFillColor(red: 0.23, green: 0.70, blue: 0.55, alpha: 0.12)
        context.addPath(path)
        context.fillPath(using: .winding)
        if zoomScale > 0 {
            context.setStrokeColor(red: 0.17, green: 0.49, blue: 0.38, alpha: 0.60)
            // Keep the boundary one screen point at every map scale.
            context.setLineWidth(1 / zoomScale)
            context.setLineJoin(.round)
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }
}
