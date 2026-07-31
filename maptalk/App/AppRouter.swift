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
                .tabItem { Label("Chats", systemImage: "message") }
                .tag(1)

            UserMapView(
                viewModel: .init(
                    environment: environment,
                    context: .me,
                    dataScope: .privateArchive
                )
            )
                .tabItem { Label("MyMap", systemImage: "square.stack.3d.up") }
                .tag(2)

            NavigationStack {
                UserProfileView(
                    viewModel: .init(environment: environment, context: .me),
                    showsSettingsButton: true
                )
            }
                .tabItem {
                    Label {
                        Text("Me")
                    } icon: {
                        Image("MeTabAvatar")
                            .renderingMode(.original)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Me")
                }
                .tag(3)
        }
        .tint(.black)
    }
}
