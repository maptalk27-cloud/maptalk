import Combine
import Foundation
import Observation
import SwiftUI

@Observable
final class AppEnvironment {
    let build: Build
    let location: any LocationService
    let notifications: any NotificationService
    let poiRepo: any POIRepository
    let ratingRepo: any RatingRepository
    let realRepo: any RealRepository

    init(
        build: Build,
        location: any LocationService,
        notifications: any NotificationService,
        poiRepo: any POIRepository,
        ratingRepo: any RatingRepository,
        realRepo: any RealRepository
    ) {
        self.build = build
        self.location = location
        self.notifications = notifications
        self.poiRepo = poiRepo
        self.ratingRepo = ratingRepo
        self.realRepo = realRepo
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
        let ratingRepo = InMemoryRatingRepository()
        let realRepo = InMemoryRealRepository()

        return AppEnvironment(
            build: build,
            location: location,
            notifications: notifications,
            poiRepo: poiRepo,
            ratingRepo: ratingRepo,
            realRepo: realRepo
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
