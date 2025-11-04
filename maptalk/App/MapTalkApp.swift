import SwiftUI

@main
struct MapTalkApp: App {
    @State private var environment = AppEnvironment.bootstrap()

    var body: some Scene {
        WindowGroup {
            AppRouter()
                .appEnvironment(environment)
        }
    }
}
