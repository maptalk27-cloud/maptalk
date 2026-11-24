#if DEBUG && targetEnvironment(simulator)
import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Visual experiments only. This file is absent from device and Release builds.
enum PostLocationPreviewStyle: String, CaseIterable, Identifiable {
    case original, mint, focus, memories

    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "原版"
        case .mint: "薄荷边界"
        case .focus: "清晰留白"
        case .memories: "记忆照片"
        }
    }
}

struct PostLocationPreviewPin: Identifiable {
    let id: UUID
    let name: String
    let count: Int
    let coordinate: CLLocationCoordinate2D
    /// A bundled fixture name, or a public thumbnail URL used only by this preview.
    let imageName: String
}

/// Keeps native Apple-map gestures, camera state, and annotation hit testing.
/// Neither panning nor changing the visual treatment rebuilds historical geometry.
struct PostLocationDesignMap: UIViewRepresentable {
    let style: PostLocationPreviewStyle
    let areas: [CLLocationCoordinate2D]
    let pins: [PostLocationPreviewPin]
    let origin: CLLocationCoordinate2D
    let camera: MKCoordinateRegion
    let cameraID: UUID
    let onMove: (CLLocationCoordinate2D) -> Void
    let onSelect: (PostLocationPreviewPin) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.showsTraffic = false
        map.pointOfInterestFilter = .excludingAll
        map.overrideUserInterfaceStyle = .light
        map.accessibilityIdentifier = "post-location.preview.native-map"
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let styleChanged = coordinator.appliedStyle != style
        if styleChanged {
            let configuration = MKStandardMapConfiguration(
                elevationStyle: .flat,
                emphasisStyle: style == .focus || style == .memories ? .muted : .default)
            configuration.pointOfInterestFilter = .excludingAll
            configuration.showsTraffic = false
            map.preferredConfiguration = configuration
        }
        coordinator.updateCoverage(in: map, styleChanged: styleChanged)
        coordinator.updatePins(in: map, styleChanged: styleChanged)
        coordinator.updateOrigin(in: map)
        coordinator.appliedStyle = style

        // The ID, not a view update or style change, is the explicit camera command.
        if coordinator.appliedCameraID != cameraID {
            let initial = coordinator.appliedCameraID == nil
            coordinator.appliedCameraID = cameraID
            map.setRegion(camera, animated: !initial)
        }
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        map.delegate = nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PostLocationDesignMap
        var appliedStyle: PostLocationPreviewStyle?
        var appliedCameraID: UUID?
        private var areaKeys: [CoordinateKey] = []
        private var geometry: PreviewCoverageGeometry?
        private var coverage: PreviewCoverageOverlay?
        private var pinKeys: [PinKey] = []
        private var annotations: [PreviewHistoryAnnotation] = []
        private let originAnnotation = MKPointAnnotation()
        private var hasOrigin = false

        init(parent: PostLocationDesignMap) { self.parent = parent }

        func updateCoverage(in map: MKMapView, styleChanged: Bool) {
            let keys = Array(Set((parent.areas + [parent.origin])
                .filter(CLLocationCoordinate2DIsValid).map { CoordinateKey($0) }))
                .sorted { ($0.latitude, $0.longitude) < ($1.latitude, $1.longitude) }
            let geometryChanged = geometry == nil || keys != areaKeys
            guard geometryChanged || styleChanged else { return }
            if geometryChanged {
                areaKeys = keys
                geometry = PreviewCoverageGeometry(centers: keys.map(\.coordinate))
            }
            if let coverage { map.removeOverlay(coverage) }
            guard let geometry else { return }
            let paint: PreviewCoveragePaint
            switch parent.style {
            case .original:
                paint = .init(fill: UIColor.systemTeal.withAlphaComponent(0.09).cgColor,
                              outline: nil, isExterior: false)
            case .mint:
                paint = .init(fill: UIColor(red: 0.23, green: 0.70, blue: 0.55, alpha: 0.12).cgColor,
                              outline: UIColor(red: 0.17, green: 0.49, blue: 0.38, alpha: 0.60).cgColor,
                              isExterior: false)
            case .focus:
                paint = .init(fill: UIColor(red: 0.93, green: 0.93, blue: 0.91, alpha: 0.68).cgColor,
                              outline: UIColor.black.withAlphaComponent(0.12).cgColor,
                              isExterior: true)
            case .memories:
                paint = .init(fill: UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 0.46).cgColor,
                              outline: UIColor(red: 0.48, green: 0.43, blue: 0.34, alpha: 0.18).cgColor,
                              isExterior: true)
            }
            let overlay = PreviewCoverageOverlay(geometry: geometry, paint: paint)
            coverage = overlay
            map.addOverlay(overlay, level: .aboveRoads)
        }

        func updatePins(in map: MKMapView, styleChanged: Bool) {
            let keys = parent.pins.map { PinKey($0) }
            guard keys != pinKeys || styleChanged else { return }
            pinKeys = keys
            map.removeAnnotations(annotations)
            annotations = parent.pins.map { PreviewHistoryAnnotation(pin: $0) }
            map.addAnnotations(annotations)
        }

        func updateOrigin(in map: MKMapView) {
            guard CLLocationCoordinate2DIsValid(parent.origin) else { return }
            if !hasOrigin {
                originAnnotation.title = "You are here"
                originAnnotation.coordinate = parent.origin
                map.addAnnotation(originAnnotation)
                hasOrigin = true
            } else if originAnnotation.coordinate.latitude != parent.origin.latitude
                        || originAnnotation.coordinate.longitude != parent.origin.longitude {
                originAnnotation.coordinate = parent.origin
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = mapView.region.center
            DispatchQueue.main.async { [weak self] in self?.parent.onMove(center) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard overlay is PreviewCoverageOverlay else { return MKOverlayRenderer(overlay: overlay) }
            return PreviewCoverageRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let history = annotation as? PreviewHistoryAnnotation else {
                guard annotation === originAnnotation else { return nil }
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "preview-origin")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "preview-origin")
                view.annotation = annotation
                view.frame.size = .init(width: 16, height: 16)
                view.backgroundColor = .systemBlue
                view.layer.cornerRadius = 8
                view.layer.borderColor = UIColor.white.cgColor
                view.layer.borderWidth = 3
                view.layer.shadowColor = UIColor.black.cgColor
                view.layer.shadowOpacity = 0.16
                view.layer.shadowRadius = 3
                view.isEnabled = false
                view.displayPriority = .required
                view.accessibilityLabel = "You are here"
                return view
            }
            if parent.style == .original || parent.style == .mint {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "preview-marker")
                    as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "preview-marker")
                view.annotation = annotation
                view.markerTintColor = .black
                view.glyphText = String(history.pin.count)
                view.glyphTintColor = .white
                view.titleVisibility = .adaptive
                view.subtitleVisibility = .hidden
                view.displayPriority = .required
                view.canShowCallout = false
                view.accessibilityLabel = "\(history.pin.name), \(history.pin.count) posts"
                view.accessibilityHint = "Reuse this Post location"
                view.accessibilityIdentifier = "post-location.preview.pin.\(history.pin.id.uuidString)"
                return view
            }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "preview-card")
                as? PreviewHistoryCardView
                ?? PreviewHistoryCardView(annotation: annotation, reuseIdentifier: "preview-card")
            view.annotation = annotation
            view.configure(pin: history.pin, style: parent.style)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let history = annotation as? PreviewHistoryAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            // Reusing an existing point is always allowed, including outside coverage.
            parent.onSelect(history.pin)
        }
    }
}

private struct CoordinateKey: Hashable {
    let latitude: Double
    let longitude: Double
    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

private struct PinKey: Equatable {
    let id: UUID
    let name: String
    let count: Int
    let coordinate: CoordinateKey
    let imageName: String
    init(_ pin: PostLocationPreviewPin) {
        id = pin.id
        name = pin.name
        count = pin.count
        coordinate = .init(pin.coordinate)
        imageName = pin.imageName
    }
}

private final class PreviewHistoryAnnotation: NSObject, MKAnnotation {
    let pin: PostLocationPreviewPin
    nonisolated let coordinate: CLLocationCoordinate2D
    nonisolated let title: String?
    init(pin: PostLocationPreviewPin) {
        self.pin = pin
        coordinate = pin.coordinate
        title = pin.name
    }
}

/// Geometry and render inputs are immutable because MapKit can draw off-main.
private nonisolated final class PreviewCoverageGeometry {
    let path: CGPath

    init(centers: [CLLocationCoordinate2D]) {
        var merged: CGPath = CGMutablePath()
        for center in centers {
            let circle = MKCircle(center: center, radius: 5_000).boundingMapRect
            var rectangles = [CGRect(x: circle.minX, y: circle.minY,
                                     width: circle.size.width, height: circle.size.height)]
            if circle.minX < MKMapRect.world.minX {
                rectangles.append(rectangles[0].offsetBy(dx: MKMapRect.world.size.width, dy: 0))
            } else if circle.maxX > MKMapRect.world.maxX {
                rectangles.append(rectangles[0].offsetBy(dx: -MKMapRect.world.size.width, dy: 0))
            }
            for rect in rectangles {
                let disk = CGPath(ellipseIn: rect, transform: nil)
                merged = merged.isEmpty ? disk : merged.union(disk)
            }
        }
        path = merged
    }
}

private nonisolated struct PreviewCoveragePaint {
    let fill: CGColor
    let outline: CGColor?
    let isExterior: Bool
}

private nonisolated final class PreviewCoverageOverlay: NSObject, MKOverlay {
    let geometry: PreviewCoverageGeometry
    let paint: PreviewCoveragePaint
    let boundingMapRect = MKMapRect.world
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)

    init(geometry: PreviewCoverageGeometry, paint: PreviewCoveragePaint) {
        self.geometry = geometry
        self.paint = paint
    }
}

private nonisolated final class PreviewCoverageRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let coverage = overlay as? PreviewCoverageOverlay else { return }
        let localOrigin = point(for: MKMapPoint(x: 0, y: 0))
        var transform = CGAffineTransform(translationX: localOrigin.x, y: localOrigin.y)
        guard let union = coverage.geometry.path.copy(using: &transform) else { return }
        let clip = rect(for: mapRect)
        context.saveGState()
        context.clip(to: clip)
        context.setFillColor(coverage.paint.fill)
        if coverage.paint.isExterior {
            // One even-odd fill punches the union out of the veil, not one hole
            // per circle (which would incorrectly re-fill their intersections).
            context.addRect(clip)
            context.addPath(union)
            context.fillPath(using: .evenOdd)
        } else {
            context.addPath(union)
            context.fillPath(using: .winding)
        }
        if let outline = coverage.paint.outline, zoomScale > 0 {
            context.addPath(union)
            context.setStrokeColor(outline)
            context.setLineWidth(1 / zoomScale)
            context.setLineJoin(.round)
            context.strokePath()
        }
        context.restoreGState()
    }
}

private final class PreviewHistoryCardView: MKAnnotationView {
    private let card = UIView()
    private let thumbnail = UIImageView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let tip = UIView()
    private var imageTask: Task<Void, Never>?
    private var representedImageName: String?
    private static var imageCache: [String: UIImage] = [:]

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        addSubview(tip)
        addSubview(card)
        addSubview(thumbnail)
        addSubview(titleLabel)
        addSubview(countLabel)
        canShowCallout = false
        displayPriority = .required
        collisionMode = .rectangle
        backgroundColor = .clear
        titleLabel.textColor = .black
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.isUserInteractionEnabled = false
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.tintColor = UIColor.black.withAlphaComponent(0.3)
        countLabel.textAlignment = .center
        countLabel.textColor = .white
        countLabel.backgroundColor = UIColor(white: 0.12, alpha: 1)
        countLabel.font = .systemFont(ofSize: 10, weight: .bold)
        countLabel.clipsToBounds = true
        tip.backgroundColor = .white
        tip.transform = CGAffineTransform(rotationAngle: .pi / 4)
        card.backgroundColor = .white
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.14
        card.layer.shadowOffset = .init(width: 0, height: 2)
        card.layer.shadowRadius = 5
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        representedImageName = nil
        thumbnail.image = nil
    }

    func configure(pin: PostLocationPreviewPin, style: PostLocationPreviewStyle) {
        imageTask?.cancel()
        imageTask = nil
        representedImageName = nil
        titleLabel.text = pin.name
        countLabel.text = String(pin.count)
        accessibilityLabel = "\(pin.name), \(pin.count) posts"
        accessibilityHint = "Reuse this Post location"
        accessibilityIdentifier = "post-location.preview.pin.\(pin.id.uuidString)"
        accessibilityTraits = .button
        let titleWidth = min(130, max(52, ceil(titleLabel.intrinsicContentSize.width)))
        if style == .focus {
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            countLabel.layer.borderWidth = 0
            let width = titleWidth + 42
            frame.size = .init(width: width, height: 38)
            centerOffset = .init(x: 0, y: -19)
            card.frame = .init(x: 0, y: 0, width: width, height: 31)
            card.layer.cornerRadius = 15.5
            titleLabel.backgroundColor = .clear
            titleLabel.frame = .init(x: 11, y: 0, width: titleWidth, height: 31)
            titleLabel.layer.cornerRadius = 0
            countLabel.frame = .init(x: width - 26, y: 6, width: 19, height: 19)
            countLabel.layer.cornerRadius = 9.5
            thumbnail.isHidden = true
            tip.center = .init(x: width / 2, y: 31)
            tip.bounds.size = .init(width: 8, height: 8)
        } else {
            let width = max(80, titleWidth + 16)
            frame.size = .init(width: width, height: 81)
            centerOffset = .init(x: 0, y: -40.5)
            card.frame = .init(x: width / 2 - 28, y: 0, width: 56, height: 56)
            card.layer.cornerRadius = 14
            thumbnail.isHidden = false
            thumbnail.frame = card.frame.insetBy(dx: 3, dy: 3)
            thumbnail.layer.cornerRadius = 11
            titleLabel.frame = .init(x: 0, y: 59, width: width, height: 19)
            titleLabel.backgroundColor = .white.withAlphaComponent(0.96)
            titleLabel.layer.cornerRadius = 9.5
            titleLabel.clipsToBounds = true
            titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            countLabel.frame = .init(x: width / 2 + 12, y: 38, width: 21, height: 21)
            countLabel.layer.cornerRadius = 10.5
            countLabel.layer.borderWidth = 2
            countLabel.layer.borderColor = UIColor.white.cgColor
            tip.center = .init(x: width / 2, y: 77)
            tip.bounds.size = .init(width: 6, height: 6)
            loadImage(pin.imageName)
        }
        if style == .focus {
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            countLabel.layer.borderWidth = 0
        }
    }

    private func loadImage(_ name: String) {
        representedImageName = name
        thumbnail.image = UIImage(named: name) ?? Self.imageCache[name] ?? UIImage(systemName: "photo")
        guard Self.imageCache[name] == nil, let url = URL(string: name),
              url.scheme == "https" else { return }
        imageTask = Task { @MainActor [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = UIImage(data: data) else { return }
                Self.imageCache[name] = image
                guard self?.representedImageName == name else { return }
                self?.thumbnail.image = image
            } catch {
                // Public fixture photos are optional; local named points remain usable.
            }
        }
    }
}
#endif
