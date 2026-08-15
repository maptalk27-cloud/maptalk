import Combine
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppEnvironment {
    let build: Build
    let location: any LocationService
    let notifications: any NotificationService
    let poiRepo: any POIRepository
    /// Apple Maps-backed directory used only by the Place publisher.
    let nearbyPOIRepo: any POIRepository
    let realRepo: any RealRepository
    /// Shared local ownership for the current person's MyMap memories.
    let myMapArchive: MyMapArchiveStore

    init(
        build: Build,
        location: any LocationService,
        notifications: any NotificationService,
        poiRepo: any POIRepository,
        nearbyPOIRepo: (any POIRepository)? = nil,
        realRepo: any RealRepository,
        myMapArchive: MyMapArchiveStore
    ) {
        self.build = build
        self.location = location
        self.notifications = notifications
        self.poiRepo = poiRepo
        self.nearbyPOIRepo = nearbyPOIRepo ?? poiRepo
        self.realRepo = realRepo
        self.myMapArchive = myMapArchive
    }

    static func bootstrap() -> AppEnvironment {
        #if DEBUG
        let build = Build(configuration: .debug, featureFlags: .mock)
        #else
        let build = Build(configuration: .release, featureFlags: .prod)
        #endif
        let location = LocationServiceImpl()
        let notifications = NotificationServiceImpl()
        let poiRepo = InMemoryPOIRepository()
        let nearbyPOIRepo = ApplePOIRepository()
        let realRepo = InMemoryRealRepository()
        let myMapArchive = MyMapArchiveStore()

        return AppEnvironment(
            build: build,
            location: location,
            notifications: notifications,
            poiRepo: poiRepo,
            nearbyPOIRepo: nearbyPOIRepo,
            realRepo: realRepo,
            myMapArchive: myMapArchive
        )
    }
}

// MARK: - Environment injection helpers

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppEnvironment.bootstrap()
}

extension EnvironmentValues {
    var appEnv: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}

extension View {
    func appEnvironment(_ environment: AppEnvironment) -> some View {
        self.environment(\.appEnv, environment)
    }
}
