import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// The canonical contents of a Journey while it is being explored on a map.
///
/// A Journey is a folder, not a feed card. Every map surface therefore derives
/// its first selection, pins and pager from the same ordered set of child
/// stories instead of reconstructing an alternative member list.
@MainActor
struct MapJourneyScope {
    let journey: JourneyPost
    let storyItems: [RealStoriesRow.StoryItem]
    private let userProvider: (UUID) -> User?

    init(
        journey: JourneyPost,
        userProvider: @escaping (UUID) -> User?
    ) {
        self.journey = journey
        self.userProvider = userProvider
        storyItems = MapStoryFeed.items(for: journey, userProvider: userProvider)
    }

    /// Some Journey scopes are private, hand-arranged folders. They use the
    /// exact same map, capsule and navigation contract as a published Journey,
    /// but their member order is intentional rather than chronological.
    init(
        journey: JourneyPost,
        userProvider: @escaping (UUID) -> User?,
        storyItems: [RealStoriesRow.StoryItem]
    ) {
        self.journey = journey
        self.userProvider = userProvider
        self.storyItems = storyItems
    }

    var firstStoryItem: RealStoriesRow.StoryItem? {
        storyItems.first
    }

    var sequenceItems: [ExperienceDetailView.SequencePager.Item] {
        storyItems.compactMap { item in
            switch item.source {
            case let .real(real):
                return .init(id: item.id, mode: .real(real, userProvider(real.userId)))
            case let .poi(group):
                return .init(id: item.id, mode: .poi(group.ratedPOI))
            case .journey:
                // Journey feeds intentionally contain children only. Keep this
                // guard so a future source cannot accidentally turn the folder
                // itself into a pager page.
                return nil
            }
        }
    }

    func storyItem(for id: UUID) -> RealStoriesRow.StoryItem? {
        storyItems.first { $0.id == id }
    }
}

/// The geometry-aware camera target used when entering or returning to a
/// Journey. It mirrors the main MapTalk map: all child points fit beneath the
/// Journey header and compact capsule, and no generic city-level clamp is used.
enum MapJourneyCamera {
    /// The Journey breadcrumb and child-story rail occupy the top of the map.
    /// Keep this shared with MyMap's story jumps so the selected memory lands
    /// in the same visible area whether it was opened from the rail or pager.
    static let journeyChromeInset: CGFloat = 194

    struct Target {
        let region: MKCoordinateRegion
        let distance: CLLocationDistance
    }

    static func target(
        for journey: JourneyPost,
        size: CGSize,
        safeAreaBottom: CGFloat,
        compactFraction: CGFloat
    ) -> Target? {
        let coordinates = journey.reels.map(\.center) + journey.pois.map { $0.poi.coordinate }
        guard coordinates.isEmpty == false else { return nil }

        let fallbackSize = CGSize(width: 430, height: 932)
        let baseSize = size == .zero ? fallbackSize : size
        let viewport = MapCameraViewport(
            size: baseSize,
            topInset: journeyChromeInset,
            bottomInset: baseSize.height * compactFraction + safeAreaBottom
        )

        if coordinates.count == 1, let coordinate = coordinates.first {
            let baseRegion = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 800,
                longitudinalMeters: 800
            )
            return Target(region: viewport.framed(baseRegion), distance: 800)
        }

        var mapRect = MKMapRect.null
        for coordinate in coordinates {
            let point = MKMapPoint(coordinate)
            let eventRect = MKMapRect(
                origin: point,
                size: MKMapSize(width: 0, height: 0)
            )
            mapRect = mapRect.isNull ? eventRect : mapRect.union(eventRect)
        }

        let mapView = MKMapView(frame: CGRect(origin: .zero, size: baseSize))
        let edgePadding = UIEdgeInsets(
            top: viewport.topInset,
            left: 40,
            bottom: viewport.bottomInset,
            right: 40
        )
        let fittedRegion = MKCoordinateRegion(mapView.mapRectThatFits(mapRect, edgePadding: edgePadding))

        let spanMeters = UserMapAnnotationZoomHelper.spanMeters(for: fittedRegion)
        let multiplier: Double = coordinates.count == 2 ? 3.4 : 2.2
        return Target(region: fittedRegion, distance: max(spanMeters * multiplier, 800))
    }
}
