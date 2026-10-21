#if DEBUG
import SwiftUI
import Combine

/// A one-tap development entrance to the existing demo data. No credentials,
/// API requests or real account sessions are created by this entrance.
@MainActor
final class MockAccountSession: ObservableObject {
    @Published private(set) var environment: AppEnvironment?

    func enterDemo() {
        environment = AppEnvironment.bootstrap()
    }

    func signOut() { environment = nil }
}

private struct MockAccountSignOutKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var mockAccountSignOut: (() -> Void)? {
        get { self[MockAccountSignOutKey.self] }
        set { self[MockAccountSignOutKey.self] = newValue }
    }
}
#endif
