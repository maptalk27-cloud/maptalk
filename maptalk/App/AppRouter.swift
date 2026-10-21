import SwiftUI
import Combine
import UIKit

struct AppRouter: View {
    @Environment(\.appEnv) private var environment
    @State private var selectedTab = 0
    @State private var tabAvatarURL: URL?
    @State private var tabAvatar: UIImage?

    var body: some View {
        TabView(selection: $selectedTab) {
            MapTalkView(viewModel: .init(environment: environment))
                .tabItem { Label("MapTalk", systemImage: "map") }
                .tag(0)

            if environment.backend == nil {
                    FriendsView(viewModel: .init(environment: environment))
                .tabItem { Label("Chats", systemImage: "message") }
                .tag(1)
            }

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
                        profileTabIcon.renderingMode(.original)
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Me")
                }
                .tag(3)
        }
        .tint(.black)
        .onReceive(environment.backend?.$user.eraseToAnyPublisher()
            ?? Just(environment.currentUser).eraseToAnyPublisher()) { user in
            guard tabAvatarURL != user.avatarURL else { return }
            tabAvatar = nil
            tabAvatarURL = user.avatarURL
        }
        .task(id: tabAvatarURL) {
            guard environment.backend != nil, let url = tabAvatarURL, url.isFileURL else { return }
            do {
                let decoded = try await LocalMapImageLoader.shared.image(at: url)
                try Task.checkCancellation()
                guard tabAvatarURL == url else { return }
                tabAvatar = ProfileTabAvatar.image(from: UIImage(cgImage: decoded.image))
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, tabAvatarURL == url else { return }
                tabAvatar = nil
            }
        }
    }

    // TabView reads icon metadata rather than rendering an ordinary view. Keep
    // a concrete Image here so conditional wrappers cannot hide its color mode.
    private var profileTabIcon: Image {
        if environment.backend == nil { return Image("MeTabAvatar") }
        if let tabAvatar { return Image(uiImage: tabAvatar) }
        return Image(systemName: "person.circle")
    }
}

enum ProfileTabAvatar {
    static func image(from source: UIImage) -> UIImage {
        let size = CGSize(width: 30, height: 30)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let bounds = CGRect(origin: .zero, size: size)
            UIBezierPath(ovalIn: bounds).addClip()
            let scale = max(size.width / source.size.width, size.height / source.size.height)
            let drawnSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(in: CGRect(x: (size.width - drawnSize.width) / 2,
                y: (size.height - drawnSize.height) / 2, width: drawnSize.width, height: drawnSize.height))
        }
        // UITabBar must keep the photo's colors, not tint its opaque circle like a symbol.
        // Set this on UIImage as well as SwiftUI.Image for both tab selection states.
        return image.withRenderingMode(.alwaysOriginal)
    }
}
