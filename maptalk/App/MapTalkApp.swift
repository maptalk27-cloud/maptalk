import SwiftUI

@main
struct MapTalkApp: App {
    private let usesLocalBackend = Self.localBackendEnabled
    // Explicit local review launch only; no account is constructed or mutated
    // until the reviewer closes this isolated component playground.
    @State private var showsPOIFeedbackPreview =
        ProcessInfo.processInfo.arguments.contains("--poi-feedback-preview")
#if DEBUG && targetEnvironment(simulator)
    @State private var showsPostLocationPreview =
        ProcessInfo.processInfo.arguments.contains("--post-location-design-preview")
    @State private var showsPostLocationPickerPreview =
        ProcessInfo.processInfo.arguments.contains("--post-location-picker-preview")
#endif

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG && targetEnvironment(simulator)
                if showsPostLocationPickerPreview {
                    PostLocationPickerPreview(onClose: {
                        showsPostLocationPickerPreview = false
                        showsPostLocationPreview = false
                    })
                } else if showsPostLocationPreview {
                    PostLocationDesignPreview(onClose: { showsPostLocationPreview = false })
                } else {
                    regularRoot
                }
#else
                regularRoot
#endif
            }
            .onOpenURL { url in
                _ = SocialSignInCoordinator.shared.handleURL(url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                _ = SocialSignInCoordinator.shared.handleUniversalLink(activity)
            }
        }
    }

    private var regularRoot: some View {
        Group {
            if showsPOIFeedbackPreview {
                POIFeedbackPreview(onClose: { showsPOIFeedbackPreview = false })
            } else if usesLocalBackend, BackendDeploymentConfiguration.configuredURL != nil {
                BackendRootView()
            } else if usesLocalBackend {
                ContentUnavailableView("\(AppBrand.name) isn't configured yet",
                    systemImage: "network.slash",
                    description: Text("This build needs its secure server address. Contact the person who invited you for an updated build."))
            } else {
                MockAppRoot()
            }
        }
    }

    private static var localBackendEnabled: Bool {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
#if targetEnvironment(simulator)
        if arguments.contains("--post-location-picker-preview") { return false }
#endif
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
#if DEBUG
    @State private var showsPOICardPreview =
        ProcessInfo.processInfo.arguments.contains("--poi-card-preview")
#endif

    var body: some View {
        Group {
#if DEBUG
            if showsPOICardPreview {
                POICardDesignPreview(onClose: { showsPOICardPreview = false })
            } else if ProcessInfo.processInfo.arguments.contains("--post-layout-preview") {
                PostLayoutPreview()
            } else {
                AppRouter()
            }
#else
            AppRouter()
#endif
        }
        .appEnvironment(environment)
    }
}
