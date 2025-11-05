import Foundation
import MapKit
import UIKit

/// Pre-warms low-zoom basemap tiles so long-haul transitions show landmasses faster.
final class WorldBasemapPrefetcher {
    static let shared = WorldBasemapPrefetcher()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clearIfNeeded),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    /// Hidden container sitting in the window hierarchy to drive the warm-up map view.
    private lazy var hiddenMapContainer: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }()

    /// Invisible MKMapView that shares the same render/cache pipeline as on-screen maps.
    private lazy var hiddenPrefetchMapView: MKMapView = {
        let mapView = MKMapView(frame: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)))
        mapView.isHidden = true
        mapView.isUserInteractionEnabled = false
        mapView.showsBuildings = false
        mapView.showsCompass = false
        mapView.isRotateEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.translatesAutoresizingMaskIntoConstraints = false
        return mapView
    }()

    private let prefetchDwellDuration: TimeInterval = 0.35
    private let prefetchTimeout: TimeInterval = 2.0

    private var lastKick: Date?
    private var isPrefetching = false

    /// Warm world/hemisphere tiles once in a while.
    func prefetchGlobalBasemapIfNeeded() {
        guard ProcessInfo.processInfo.isLowPowerModeEnabled == false,
              UIAccessibility.isReduceMotionEnabled == false
        else { return }

        if let lastKick, Date().timeIntervalSince(lastKick) < 600 { return }
        lastKick = Date()

        guard isPrefetching == false else { return }
        isPrefetching = true

        guard ensureHiddenMapViewReady() else {
            isPrefetching = false
            return
        }

        let jobs: [MKCoordinateRegion] = [
            .init(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                  span: MKCoordinateSpan(latitudeDelta: 140, longitudeDelta: 360)),
            .init(center: .init(latitude: 0, longitude: -90),
                  span: .init(latitudeDelta: 120, longitudeDelta: 200)),
            .init(center: .init(latitude: 0, longitude: 90),
                  span: .init(latitudeDelta: 120, longitudeDelta: 200)),
            .init(center: .init(latitude: 40, longitude: 0),
                  span: .init(latitudeDelta: 100, longitudeDelta: 220)),
            .init(center: .init(latitude: -40, longitude: 0),
                  span: .init(latitudeDelta: 100, longitudeDelta: 220)),
            .init(center: .init(latitude: 40, longitude: -100),
                  span: .init(latitudeDelta: 60, longitudeDelta: 90)),
            .init(center: .init(latitude: 30, longitude: 10),
                  span: .init(latitudeDelta: 70, longitudeDelta: 90)),
            .init(center: .init(latitude: 25, longitude: 110),
                  span: .init(latitudeDelta: 70, longitudeDelta: 110))
        ]

        for region in jobs {
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let self, let operation, operation.isCancelled == false else { return }
                self.warmRegion(region, operation: operation)
            }
            queue.addOperation(operation)
        }

        queue.addBarrierBlock { [weak self] in
            self?.isPrefetching = false
        }
    }


    @objc private func clearIfNeeded() {
        queue.cancelAllOperations()
        isPrefetching = false
    }

    private func ensureHiddenMapViewReady() -> Bool {
        if Thread.isMainThread {
            return prepareHiddenMapViewIfNeeded()
        } else {
            var isReady = false
            let semaphore = DispatchSemaphore(value: 0)

            DispatchQueue.main.async { [weak self] in
                defer { semaphore.signal() }
                guard let self else { return }
                isReady = self.prepareHiddenMapViewIfNeeded()
            }

            semaphore.wait()
            return isReady
        }
    }

    private func prepareHiddenMapViewIfNeeded() -> Bool {
        guard let window = hostWindow() else { return false }

        let container = hiddenMapContainer
        if container.superview == nil {
            container.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                container.topAnchor.constraint(equalTo: window.topAnchor),
                container.widthAnchor.constraint(equalToConstant: 1),
                container.heightAnchor.constraint(equalToConstant: 1)
            ])
        }

        if hiddenPrefetchMapView.superview == nil {
            container.addSubview(hiddenPrefetchMapView)
            NSLayoutConstraint.activate([
                hiddenPrefetchMapView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hiddenPrefetchMapView.topAnchor.constraint(equalTo: container.topAnchor),
                hiddenPrefetchMapView.widthAnchor.constraint(equalToConstant: 1),
                hiddenPrefetchMapView.heightAnchor.constraint(equalToConstant: 1)
            ])
        }

        return true
    }

    private func hostWindow() -> UIWindow? {
        let windowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        for scene in windowScenes where scene.activationState == .foregroundActive {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return window
            }
        }

        for scene in windowScenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return window
            }
        }

        return nil
    }

    /// Walks the hidden MKMapView through the regions to trigger tile downloads.
    private func warmRegion(_ region: MKCoordinateRegion, operation: Operation) {
        guard operation.isCancelled == false else { return }
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                semaphore.signal()
                return
            }
            guard self.hiddenPrefetchMapView.superview != nil else {
                semaphore.signal()
                return
            }
            guard operation.isCancelled == false else {
                semaphore.signal()
                return
            }

            self.hiddenPrefetchMapView.setRegion(region, animated: false)

            DispatchQueue.main.asyncAfter(deadline: .now() + self.prefetchDwellDuration) {
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + prefetchTimeout)
    }
}
