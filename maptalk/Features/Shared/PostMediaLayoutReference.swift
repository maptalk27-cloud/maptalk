import SwiftUI

/// Keeps the compact reading canvas stable as a Post's sheet expands. A
/// sheet-backed pager supplies its resolved compact viewport; ordinary hosts
/// can still fall back to a recorded compact card measurement.
struct PostMediaLayoutReference {
    struct Key: Hashable {
        let postID: UUID
        let attachmentCount: Int
    }

    var resolveCard: (UUID, Int) -> CGSize? = { _, _ in nil }
    var recordCardSize: (CGSize, UUID, Int) -> Void = { _, _, _ in }

    func cardSize(for postID: UUID, count: Int) -> CGSize? {
        resolveCard(postID, count)
    }

    func recordCard(_ size: CGSize, for postID: UUID, count: Int) {
        recordCardSize(size, postID, count)
    }

    static func resolvedCardSize(viewport: CGSize?, recorded: CGSize?) -> CGSize? {
        validCardSize(viewport) ?? validCardSize(recorded)
    }

    static func validCardSize(_ size: CGSize?) -> CGSize? {
        guard let size, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size
    }
}

private struct PostMediaLayoutReferenceKey: EnvironmentKey {
    static var defaultValue: PostMediaLayoutReference { PostMediaLayoutReference() }
}

private struct PostCompactViewportSizeKey: EnvironmentKey {
    static var defaultValue: CGSize? { nil }
}

extension EnvironmentValues {
    var postMediaLayoutReference: PostMediaLayoutReference {
        get { self[PostMediaLayoutReferenceKey.self] }
        set { self[PostMediaLayoutReferenceKey.self] = newValue }
    }

    /// Full card size at the compact stop, not the current animated sheet size.
    /// Keep supplying it while expanded so a recreated page has the same media
    /// budget without depending on a previous onGeometryChange callback.
    var postCompactViewportSize: CGSize? {
        get { self[PostCompactViewportSizeKey.self] }
        set { self[PostCompactViewportSizeKey.self] = newValue }
    }
}
