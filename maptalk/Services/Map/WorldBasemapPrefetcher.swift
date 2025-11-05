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

        let size = CGSize(width: 512, height: 512)

        for region in jobs {
            queue.addOperation { [weak self] in
                guard let self else { return }
                var options = MKMapSnapshotter.Options()
                options.region = region
                options.scale = 2
                options.size = size
                options.showsBuildings = false
                options.showsPointsOfInterest = false

                let snapshotter = MKMapSnapshotter(options: options)
                let semaphore = DispatchSemaphore(value: 0)
                snapshotter.start { _, _ in
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 4.0)
            }
        }

        queue.addBarrierBlock { [weak self] in
            self?.isPrefetching = false
        }
    }


    @objc private func clearIfNeeded() {
        queue.cancelAllOperations()
        isPrefetching = false
    }
}
