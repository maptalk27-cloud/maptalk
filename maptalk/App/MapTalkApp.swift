import SwiftUI

@main
struct MapTalkApp: App {
    private let usesLocalBackend = Self.localBackendEnabled

    var body: some Scene {
        WindowGroup {
            Group {
                if usesLocalBackend, BackendDeploymentConfiguration.configuredURL != nil {
                    BackendRootView()
                } else if usesLocalBackend {
                    ContentUnavailableView("MapTalk isn't configured yet",
                        systemImage: "network.slash",
                        description: Text("This build needs its secure server address. Contact the person who invited you for an updated build."))
                } else {
                    MockAppRoot()
                }
            }
            .onOpenURL { url in
                _ = SocialSignInCoordinator.shared.handleURL(url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                _ = SocialSignInCoordinator.shared.handleUniversalLink(activity)
            }
        }
    }

    private static var localBackendEnabled: Bool {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--mock-data") { return false }
        if arguments.contains("--local-backend") {
            if ProcessInfo.processInfo.environment["MAPTALK_ACCOUNT_TEST_NAMESPACE"] == nil {
                UserDefaults.standard.set(true, forKey: "maptalk.localBackend")
            }
            return true
        }
        return BackendDeploymentConfiguration.isHosted || UserDefaults.standard.bool(forKey: "maptalk.localBackend")
#else
        return true
#endif
    }
}

/// Build preview repositories only when actually entering the preview app.
private struct MockAppRoot: View {
    @State private var environment = AppEnvironment.bootstrap()

    var body: some View {
        AppRouter().appEnvironment(environment)
    }
}
