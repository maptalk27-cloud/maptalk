import SwiftUI

struct AppRouter: View {
    @Environment(\.appEnv) private var environment
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            MapTalkView(viewModel: .init(environment: environment))
                .tabItem { Label("MapTalk", systemImage: "map") }
                .tag(0)

            FriendsView(viewModel: .init(environment: environment))
                .tabItem { Label("Friends", systemImage: "person.2") }
                .tag(1)

            RealFeedView(viewModel: .init(environment: environment))
                .tabItem { Label("Real", systemImage: "sparkles") }
                .tag(2)

            MySettingsView()
                .tabItem { Label("My", systemImage: "person.crop.circle") }
                .tag(3)
        }
        .accentColor(Theme.neonPrimary)
    }
}
