import CoreGraphics
import Foundation

/// Only overlap membership is throttled. Callers project marker positions on
/// every camera update, so cached stacks still follow the live map camera.
struct MyMapHitLayout {
    struct Marker {
        let id: UUID
        let point: CGPoint
    }

    static let overlapRadius: CGFloat = 34
    static let refreshInterval: TimeInterval = 1.0 / 12.0

    private var lastRefresh: TimeInterval?
    private var visibleIDs: [UUID] = []
    private var memberships: [[UUID]] = []

    mutating func invalidate() {
        lastRefresh = nil
    }

    mutating func groups(
        for markers: [Marker],
        at time: TimeInterval,
        exact: Bool = false
    ) -> [[UUID]] {
        let ids = markers.map(\.id)
        if exact || lastRefresh == nil || visibleIDs != ids
            || time - (lastRefresh ?? time) >= Self.refreshInterval {
            memberships = Self.group(markers)
            visibleIDs = ids
            lastRefresh = time
            return memberships
        }

        // Zooming in can split a sampled stack before the next full overlap
        // pass. Recheck only its own members so its averaged hit circle never
        // stays in a newly opened gap. Singletons require no distance checks;
        // cross-stack merging remains throttled and taps resolve it live.
        let byID = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, $0) })
        return memberships.flatMap { ids in
            Self.group(ids.compactMap { byID[$0] })
        }
    }

    /// Preserve the existing ordered, physical-overlap grouping contract;
    /// coordinate/place identity alone cannot determine screen overlap.
    static func group(_ markers: [Marker]) -> [[UUID]] {
        var clusters: [[Marker]] = []
        for marker in markers {
            if let index = clusters.indices.first(where: { index in
                clusters[index].contains {
                    let dx = marker.point.x - $0.point.x
                    let dy = marker.point.y - $0.point.y
                    return dx * dx + dy * dy <= overlapRadius * overlapRadius
                }
            }) {
                clusters[index].append(marker)
            } else {
                clusters.append([marker])
            }
        }
        return clusters.map { $0.map(\.id) }
    }
}
