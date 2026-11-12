import SwiftUI

enum PostEngagementSection: String, Hashable {
    case likes, comments
}

struct PostEngagementRequest {
    let id = UUID()
    let postID: UUID
    let section: PostEngagementSection
}

private struct OpenPostEngagementKey: EnvironmentKey {
    static var defaultValue: ((UUID, PostEngagementSection) -> Void)? { nil }
}

private struct PostEngagementRequestKey: EnvironmentKey {
    static var defaultValue: PostEngagementRequest? { nil }
}

extension EnvironmentValues {
    var openPostEngagement: ((UUID, PostEngagementSection) -> Void)? {
        get { self[OpenPostEngagementKey.self] }
        set { self[OpenPostEngagementKey.self] = newValue }
    }

    var postEngagementRequest: PostEngagementRequest? {
        get { self[PostEngagementRequestKey.self] }
        set { self[PostEngagementRequestKey.self] = newValue }
    }
}

struct PostEngagementButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.07 : 0),
                        in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
