import CoreLocation
import MapKit
import Testing
@testable import maptalk

@MainActor
struct PostLocationMarkerTests {
    @Test
    func thumbnailHostKeepsItsContentTypeAcrossSelectionAndReuse() {
        let first = choice(id: "first", title: "First place", latitude: 47.606)
        let second = choice(id: "second", title: "Second place", latitude: 21.3)
        let marker = PostLocationThumbnailAnnotationView(annotation: nil, reuseIdentifier: "post-marker-test")

        // The first configure and the reuse clear formerly assigned different
        // UIHostingConfiguration Content types and crashed in UIKit's setter.
        marker.configure(choice: first, selected: false)
        #expect(marker.accessibilityLabel == "First place")
        #expect(!marker.accessibilityTraits.contains(.selected))

        marker.configure(choice: first, selected: true)
        #expect(marker.accessibilityTraits.contains(.selected))

        marker.prepareForReuse()
        #expect(marker.accessibilityLabel == nil)
        #expect(!marker.accessibilityTraits.contains(.selected))

        marker.configure(choice: second, selected: false)
        #expect(marker.accessibilityLabel == "Second place")
        #expect(marker.accessibilityIdentifier == "maptalk.post.location-marker.second")
        #expect(!marker.accessibilityTraits.contains(.selected))
    }

    private func choice(id: String, title: String, latitude: Double) -> MapTalkPostLocationChoice {
        .init(id: id,
              selection: .init(coordinate: .init(latitude: latitude, longitude: -122.332),
                               title: title, locationName: title),
              distanceMeters: 0, category: nil, previousPosts: [], cachedThumbnail: nil)
    }
}
