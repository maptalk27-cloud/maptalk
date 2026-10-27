import Foundation
import Testing
@testable import maptalk

@MainActor
struct PostPresentationDateTests {
    @Test
    func publicCardUsesPublicationButPrivateMemoryKeepsCaptureDate() {
        var post = PreviewData.sampleReals[0]
        post.createdAt = Date(timeIntervalSince1970: 1_792_670_400)
        post.publishedAt = post.createdAt.addingTimeInterval(4 * 86_400)
        post.visibility = .publicAll
        #expect(post.cardDisplayDate == post.publishedAt)
        post.visibility = .privateOnly
        #expect(post.cardDisplayDate == post.createdAt)
        post.visibility = .publicAll
        post.publishedAt = nil
        #expect(post.cardDisplayDate == post.createdAt)
    }
}
