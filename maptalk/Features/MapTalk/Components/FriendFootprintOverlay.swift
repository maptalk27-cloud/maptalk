import Combine
import MapKit
import SwiftUI

/// A quiet, place-level projection of older friend activity. The projection
/// stays separate from the live story layer, while its canonical place data is
/// shared with the normal POI experience so one place never grows a second UI.
struct MapTalkFriendFootprint: Identifiable {
    let id: String
    let ratedPOI: RatedPOI
    let friendIDs: [UUID]

    var placeName: String { ratedPOI.poi.name }
    var coordinate: CLLocationCoordinate2D { ratedPOI.poi.coordinate }
    var category: POICategory { ratedPOI.poi.category }

    init(id: String, ratedPOI: RatedPOI, friendIDs: [UUID]) {
        self.id = id
        self.ratedPOI = ratedPOI
        self.friendIDs = friendIDs
    }

    /// The server supplies only visible public visits. The legacy name is kept
    /// for the existing renderer; these IDs are visitors, not fabricated friends.
    static func history(for place: RatedPOI, asOf now: Date) -> MapTalkFriendFootprint? {
        guard !place.checkIns.isEmpty,
              place.checkIns.allSatisfy({ $0.activityDate.addingTimeInterval(StoryReadKeys.freshWindow) <= now }) else {
            return nil
        }
        return MapTalkFriendFootprint(
            id: "place-\(place.id.uuidString)",
            ratedPOI: place,
            friendIDs: place.checkInPeople().map(\.userID)
        )
    }

    /// Preview footprints still carry real POI-shaped data. That lets the map
    /// prototype exercise the production card without promoting these older
    /// traces into the live POI repository or story shelf.
    init(
        id: String,
        placeName: String,
        coordinate: CLLocationCoordinate2D,
        category: POICategory,
        friendIDs: [UUID]
    ) {
        self.id = id
        self.friendIDs = friendIDs

        let checkIns = friendIDs.enumerated().map { index, userID in
            RatedPOI.CheckIn(
                userId: userID,
                createdAt: Date.now.addingTimeInterval(-Double(index + 2) * 86_400),
                tag: .explore
            )
        }
        ratedPOI = RatedPOI(
            poi: POI(
                id: UUID(),
                name: placeName,
                coordinate: coordinate,
                category: category
            ),
            highlight: nil,
            secondary: nil,
            media: [],
            checkIns: checkIns,
            comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0),
            tags: friendIDs.isEmpty
                ? []
                : [.init(tag: .explore, count: friendIDs.count)],
            isFavoritedByCurrentUser: false,
            favoritesCount: 0
        )
    }
}

struct FriendFootprintViewportLayout {
    let places: [MapTalkFriendFootprint]
}

struct FriendFootprintScreenVisibility: Equatable {
    let placeIDs: Set<String>
    let expandedPlaceIDs: Set<String>
    let densityStyle: FriendFootprintDensityStyle
}

struct FriendFootprintProjectedPlace {
    let id: String
    let point: CGPoint
    let friendCount: Int
}

/// Reusing the settled representatives is desirable for a pan, but not for a
/// zoom: after scale changes, the old set may collapse into the center and
/// leave newly revealed geography empty. Region span gives this policy a small,
/// deterministic way to tell those interactions apart.
enum FriendFootprintSamplingContinuityPolicy {
    static let maximumScaleRatio = 1.08

    static func shouldPreserveRepresentatives(
        from previousRegion: MKCoordinateRegion?,
        to nextRegion: MKCoordinateRegion
    ) -> Bool {
        guard let previousRegion else { return false }
        return scaleRatio(
            previousRegion.span.latitudeDelta,
            nextRegion.span.latitudeDelta
        ) <= maximumScaleRatio
            && scaleRatio(
                previousRegion.span.longitudeDelta,
                nextRegion.span.longitudeDelta
            ) <= maximumScaleRatio
    }

    private static func scaleRatio(_ lhs: Double, _ rhs: Double) -> Double {
        let smaller = max(1e-9, min(abs(lhs), abs(rhs)))
        return max(abs(lhs), abs(rhs)) / smaller
    }
}

enum FriendFootprintDensityStyle: Equatable {
    case sparse
    case medium
    case dense

    /// Compact history stays deliberately simple. Density is expressed by
    /// sampling, not by shrinking markers until they become visual noise.
    var compactMarkerSize: CGFloat {
        12
    }

    var compactMarkerOpacity: Double {
        0.84
    }

    var compactMarkerStrokeWidth: CGFloat {
        1
    }

    var compactMarkerStrokeOpacity: Double {
        0.9
    }

    var automaticMarkerCapacity: Int {
        switch self {
        case .sparse: 8
        case .medium: 3
        case .dense: 2
        }
    }

    var automaticMarkerSpacing: CGFloat {
        switch self {
        case .sparse: 82
        case .medium: 96
        case .dense: 112
        }
    }

    /// Compact history is a screen-space layer, so its budget scales with the
    /// amount of map the device can actually show instead of a hard-coded
    /// global record count.
    var visibleMarkerCellSize: CGFloat {
        switch self {
        case .sparse: 32
        case .medium: 40
        case .dense: 48
        }
    }

    /// Compact history is a real control, but its hit target stays close to
    /// the visible circle so dense city texture does not blanket the map.
    var compactControlSize: CGFloat {
        16
    }
}

/// Screen-space chrome is not part of the geographic viewport. Quiet history
/// markers disappear while their visual bounds would sit behind the live
/// story shelf; the place itself never moves away from its true coordinate.
enum FriendFootprintScreenOcclusionPolicy {
    static let markerClearance: CGFloat = 32
    static let compactMarkerClearance: CGFloat = 16

    static func isCoveredByControls(projectedPoint: CGPoint, controlsFrame: CGRect) -> Bool {
        guard !controlsFrame.isEmpty else { return false }
        // Account for the full expanded diamond as well as the small circle.
        // Coordinates stay geographic; obscured controls simply aren't drawn.
        return controlsFrame.insetBy(dx: -markerClearance, dy: -markerClearance)
            .contains(projectedPoint)
    }

    static func isOccluded(
        projectedPoint: CGPoint?,
        canvasSize: CGSize,
        topChromeBottom: CGFloat,
        clearance: CGFloat = markerClearance
    ) -> Bool {
        guard topChromeBottom > 0 else { return true }
        guard let point = projectedPoint else { return false }

        let isNearVisibleWidth = point.x >= -clearance
            && point.x <= canvasSize.width + clearance
        let canStillAppearAtTop = point.y >= -clearance

        return isNearVisibleWidth
            && canStillAppearAtTop
            && point.y < topChromeBottom + clearance
    }
}

/// The repository retains every footprint. The settled screen renders a stable,
/// spatially fair sample so history reads as city texture instead of a database
/// dump. Every representative is a quiet compact circle; only a few high-value
/// representatives expand into rich, directly interactive diamonds.
enum FriendFootprintScreenLayoutPolicy {
    static let primaryPointClearance: CGFloat = 66
    // The largest live Reel marker is an 84pt square. Using the same conservative
    // corner clearance for quiet history prevents a compact marker from
    // sitting in a live marker's real tap region with no way to select it.
    static let historyPointYieldClearance = primaryPointClearance
    static let automaticMarkerCollapseSpacing: CGFloat = 66
    static let expandedMarkerAreaBudget: CGFloat = 42_000
    static let minimumExpandedMarkerCapacity = 4
    static let maximumExpandedMarkerCapacity = 8
    static let mediumDensityThreshold: CGFloat = 3
    static let mediumDensityExitThreshold: CGFloat = 2
    static let denseDensityThreshold: CGFloat = 9
    static let denseDensityExitThreshold: CGFloat = 7

    static func visibility(
        projectedPlaces: [FriendFootprintProjectedPlace],
        reservedPoints: [CGPoint],
        canvasSize: CGSize,
        topChromeBottom: CGFloat,
        selectedID: String?,
        previouslyVisibleIDs: Set<String> = [],
        previouslyExpandedIDs: Set<String> = [],
        previousDensityStyle: FriendFootprintDensityStyle? = nil
    ) -> FriendFootprintScreenVisibility {
        guard topChromeBottom > 0 else {
            return FriendFootprintScreenVisibility(
                placeIDs: [],
                expandedPlaceIDs: [],
                densityStyle: .sparse
            )
        }

        var primaryIndex = SpatialPointIndex(cellSize: primaryPointClearance)
        for point in reservedPoints where point.x.isFinite && point.y.isFinite {
            primaryIndex.insert(point)
        }
        let usableHeight = max(1, canvasSize.height - max(0, topChromeBottom))
        let usableArea = max(1, canvasSize.width) * usableHeight
        let candidates = projectedPlaces.filter { place in
            let point = place.point
            guard point.x.isFinite,
                  point.y.isFinite,
                  point.x >= -FriendFootprintScreenOcclusionPolicy.compactMarkerClearance,
                  point.x <= canvasSize.width + FriendFootprintScreenOcclusionPolicy.compactMarkerClearance,
                  point.y >= -FriendFootprintScreenOcclusionPolicy.compactMarkerClearance,
                  point.y <= canvasSize.height + FriendFootprintScreenOcclusionPolicy.compactMarkerClearance else {
                return false
            }

            guard FriendFootprintScreenOcclusionPolicy.isOccluded(
                projectedPoint: point,
                canvasSize: canvasSize,
                topChromeBottom: topChromeBottom,
                clearance: FriendFootprintScreenOcclusionPolicy.compactMarkerClearance
            ) == false else {
                return false
            }

            return true
        }

        let densityStyle = densityStyle(
            visibleCount: candidates.count,
            usableArea: usableArea,
            previousStyle: previousDensityStyle
        )
        let expandedMarkerCapacity = min(
            densityStyle.automaticMarkerCapacity,
            min(
                maximumExpandedMarkerCapacity,
                max(
                    minimumExpandedMarkerCapacity,
                    Int(usableArea / expandedMarkerAreaBudget)
                )
            )
        )

        // A live story is already the richer entrance for its location. Quiet
        // history yields there instead of drawing and hit-testing underneath
        // it. A selected history place is retained so an open preview never
        // loses its visual anchor.
        let renderCandidates = candidates.filter { candidate in
            candidate.id == selectedID
                || primaryIndex.contains(
                    candidate.point,
                    within: historyPointYieldClearance
                ) == false
        }
        let stablePreviousIDs = previousDensityStyle == nil
            || previousDensityStyle == densityStyle
            ? previouslyVisibleIDs
            : []
        let sampledCandidates = visibleRepresentatives(
            from: renderCandidates,
            canvasSize: canvasSize,
            topChromeBottom: topChromeBottom,
            densityStyle: densityStyle,
            selectedID: selectedID,
            previouslyVisibleIDs: stablePreviousIDs
        )
        let visibleIDs = Set(sampledCandidates.map(\.id))

        // Friend count is the only real relevance signal in the current model.
        // Previous expansion is a tie-breaker for visual stability, not a way
        // to permanently lock a lower-value place above a stronger one.
        let detailCandidates = sampledCandidates.sorted { lhs, rhs in
            if lhs.friendCount != rhs.friendCount {
                return lhs.friendCount > rhs.friendCount
            }
            let lhsWasExpanded = previouslyExpandedIDs.contains(lhs.id)
            let rhsWasExpanded = previouslyExpandedIDs.contains(rhs.id)
            if lhsWasExpanded != rhsWasExpanded { return lhsWasExpanded }
            return lhs.id < rhs.id
        }
        var expandedIDs: Set<String> = []
        expandedIDs.reserveCapacity(expandedMarkerCapacity + 1)
        var expandedPointIndex = SpatialPointIndex(
            cellSize: densityStyle.automaticMarkerSpacing
        )
        var automaticExpandedCount = 0

        if let selected = sampledCandidates.first(where: { $0.id == selectedID }) {
            expandedIDs.insert(selected.id)
            expandedPointIndex.insert(selected.point, id: selected.id)
        }

        for candidate in detailCandidates {
            guard automaticExpandedCount < expandedMarkerCapacity else { break }
            guard candidate.id != selectedID else { continue }

            guard primaryIndex.contains(
                candidate.point,
                within: primaryPointClearance
            ) == false else {
                continue
            }

            let spacing = previouslyExpandedIDs.contains(candidate.id)
                ? max(
                    automaticMarkerCollapseSpacing,
                    densityStyle.automaticMarkerSpacing - 16
                )
                : densityStyle.automaticMarkerSpacing
            guard expandedPointIndex.contains(
                candidate.point,
                within: spacing,
                excludingID: candidate.id
            ) == false else {
                continue
            }
            expandedIDs.insert(candidate.id)
            expandedPointIndex.insert(candidate.point, id: candidate.id)
            automaticExpandedCount += 1
        }

        return FriendFootprintScreenVisibility(
            placeIDs: visibleIDs,
            expandedPlaceIDs: expandedIDs,
            densityStyle: densityStyle
        )
    }

    static func densityStyle(
        visibleCount: Int,
        usableArea: CGFloat,
        previousStyle: FriendFootprintDensityStyle? = nil
    ) -> FriendFootprintDensityStyle {
        guard visibleCount > 0, usableArea > 0 else { return .sparse }
        let pointsPerTenThousandPoints = CGFloat(visibleCount) * 10_000
            / usableArea

        if previousStyle == .dense {
            if pointsPerTenThousandPoints >= denseDensityExitThreshold {
                return .dense
            }
            if pointsPerTenThousandPoints >= mediumDensityExitThreshold {
                return .medium
            }
            return .sparse
        }

        if previousStyle == .medium {
            if pointsPerTenThousandPoints >= denseDensityThreshold {
                return .dense
            }
            if pointsPerTenThousandPoints >= mediumDensityExitThreshold {
                return .medium
            }
            return .sparse
        }

        if pointsPerTenThousandPoints >= denseDensityThreshold {
            return .dense
        }
        if pointsPerTenThousandPoints >= mediumDensityThreshold {
            return .medium
        }
        return .sparse
    }

    static func visibleMarkerCapacity(
        canvasSize: CGSize,
        topChromeBottom: CGFloat,
        densityStyle: FriendFootprintDensityStyle
    ) -> Int {
        renderGrid(
            canvasSize: canvasSize,
            topChromeBottom: topChromeBottom,
            cellSize: densityStyle.visibleMarkerCellSize
        ).capacity
    }

    private static func visibleRepresentatives(
        from candidates: [FriendFootprintProjectedPlace],
        canvasSize: CGSize,
        topChromeBottom: CGFloat,
        densityStyle: FriendFootprintDensityStyle,
        selectedID: String?,
        previouslyVisibleIDs: Set<String>
    ) -> [FriendFootprintProjectedPlace] {
        let grid = renderGrid(
            canvasSize: canvasSize,
            topChromeBottom: topChromeBottom,
            cellSize: densityStyle.visibleMarkerCellSize
        )
        // Sparse authored sets such as Seattle should remain untouched. Once
        // the screen reaches a city-scale density, new representatives enter
        // one per cell. The already-settled set is retained below so a pan does
        // not make points blink merely because a grid boundary moved under it.
        guard densityStyle != .sparse || candidates.count > grid.capacity else {
            return candidates
        }

        let retained = candidates.filter { candidate in
            candidate.id == selectedID || previouslyVisibleIDs.contains(candidate.id)
        }.sorted { lhs, rhs in
            let lhsIsSelected = lhs.id == selectedID
            let rhsIsSelected = rhs.id == selectedID
            if lhsIsSelected != rhsIsSelected { return lhsIsSelected }
            if lhs.friendCount != rhs.friendCount {
                return lhs.friendCount > rhs.friendCount
            }
            return lhs.id < rhs.id
        }

        var representatives: [FriendFootprintProjectedPlace] = []
        representatives.reserveCapacity(grid.capacity)
        var representativeIDs = Set<String>()
        var occupiedCells = Set<RenderCell>()

        // Retain the settled set as a group. Two representatives that cross a
        // screen-grid boundary keep the same physical separation while panning,
        // so dropping one after the gesture would only create a visible flicker.
        for candidate in retained where representatives.count < grid.capacity {
            representatives.append(candidate)
            representativeIDs.insert(candidate.id)
            occupiedCells.insert(grid.cell(containing: candidate.point))
        }

        let newcomers = candidates.filter {
            representativeIDs.contains($0.id) == false
        }.sorted { lhs, rhs in
            if lhs.friendCount != rhs.friendCount {
                return lhs.friendCount > rhs.friendCount
            }
            return lhs.id < rhs.id
        }

        for candidate in newcomers where representatives.count < grid.capacity {
            let cell = grid.cell(containing: candidate.point)
            guard occupiedCells.insert(cell).inserted else { continue }
            representatives.append(candidate)
            representativeIDs.insert(candidate.id)
        }

        return representatives
    }

    private static func renderGrid(
        canvasSize: CGSize,
        topChromeBottom: CGFloat,
        cellSize: CGFloat
    ) -> RenderGrid {
        let clearance = FriendFootprintScreenOcclusionPolicy.compactMarkerClearance
        let minX = -clearance
        let minY = max(0, topChromeBottom) - clearance
        let width = max(1, canvasSize.width + clearance * 2)
        let height = max(1, canvasSize.height - max(0, topChromeBottom) + clearance * 2)
        return RenderGrid(
            minX: minX,
            minY: minY,
            cellSize: max(1, cellSize),
            columns: max(1, Int(ceil(width / max(1, cellSize)))),
            rows: max(1, Int(ceil(height / max(1, cellSize))))
        )
    }

    private struct RenderGrid {
        let minX: CGFloat
        let minY: CGFloat
        let cellSize: CGFloat
        let columns: Int
        let rows: Int

        var capacity: Int { columns * rows }

        func cell(containing point: CGPoint) -> RenderCell {
            RenderCell(
                x: min(
                    columns - 1,
                    max(0, Int(floor((point.x - minX) / cellSize)))
                ),
                y: min(
                    rows - 1,
                    max(0, Int(floor((point.y - minY) / cellSize)))
                )
            )
        }
    }

    private struct RenderCell: Hashable {
        let x: Int
        let y: Int
    }

    private struct SpatialPointIndex {
        private struct Entry {
            let id: String?
            let point: CGPoint
        }

        private struct Cell: Hashable {
            let x: Int
            let y: Int
        }

        let cellSize: CGFloat
        private var buckets: [Cell: [Entry]] = [:]

        init(cellSize: CGFloat) {
            self.cellSize = cellSize
        }

        mutating func insert(_ point: CGPoint, id: String? = nil) {
            let cell = Cell(
                x: Int(floor(point.x / cellSize)),
                y: Int(floor(point.y / cellSize))
            )
            buckets[cell, default: []].append(Entry(id: id, point: point))
        }

        func contains(
            _ point: CGPoint,
            within distance: CGFloat,
            excludingID: String? = nil
        ) -> Bool {
            let cell = Cell(
                x: Int(floor(point.x / cellSize)),
                y: Int(floor(point.y / cellSize))
            )
            let minimumDistance = max(0, distance)
            let searchRadius = max(1, Int(ceil(minimumDistance / cellSize)))
            let squaredDistance = minimumDistance * minimumDistance

            for xOffset in -searchRadius...searchRadius {
                for yOffset in -searchRadius...searchRadius {
                    let neighbor = Cell(
                        x: cell.x + xOffset,
                        y: cell.y + yOffset
                    )
                    guard let entries = buckets[neighbor] else { continue }
                    if entries.contains(where: { candidate in
                        if let excludingID, candidate.id == excludingID {
                            return false
                        }
                        let xDistance = candidate.point.x - point.x
                        let yDistance = candidate.point.y - point.y
                        return xDistance * xDistance + yDistance * yDistance
                            <= squaredDistance
                    }) {
                        return true
                    }
                }
            }

            return false
        }
    }
}

/// Keeps the feedback for a tap visible above the compact preview. It never
/// changes zoom and does nothing unless the preview would cover the selected
/// point, so most taps leave the map completely still.
enum FriendFootprintSelectionCameraPolicy {
    static let previewClearance: CGFloat = 72
    static let topClearance: CGFloat = 44
    static let recenterStrength = 0.66

    static func targetPoint(
        projectedPoint: CGPoint?,
        canvasSize: CGSize,
        topChromeBottom: CGFloat,
        compactSheetFraction: CGFloat
    ) -> CGPoint? {
        guard let point = projectedPoint,
              point.x.isFinite,
              point.y.isFinite,
              canvasSize.width > 0,
              canvasSize.height > 0,
              compactSheetFraction > 0,
              compactSheetFraction < 1 else {
            return nil
        }

        let previewTop = canvasSize.height * (1 - compactSheetFraction)
        let targetY = max(
            topChromeBottom + topClearance,
            previewTop - previewClearance
        )
        guard targetY < previewTop - 12, point.y > targetY else {
            return nil
        }

        return CGPoint(x: point.x, y: targetY)
    }

    static func adjustedCenter(
        selectedCoordinate: CLLocationCoordinate2D,
        coordinateAtTargetPoint: CLLocationCoordinate2D,
        currentCenter: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        let latitudeDelta = selectedCoordinate.latitude
            - coordinateAtTargetPoint.latitude
        let longitudeDelta = wrappedLongitudeDelta(
            from: coordinateAtTargetPoint.longitude,
            to: selectedCoordinate.longitude
        )
        return CLLocationCoordinate2D(
            latitude: min(
                85,
                max(-85, currentCenter.latitude + latitudeDelta * recenterStrength)
            ),
            longitude: normalizedLongitude(
                currentCenter.longitude + longitudeDelta * recenterStrength
            )
        )
    }

    private static func wrappedLongitudeDelta(
        from source: CLLocationDegrees,
        to destination: CLLocationDegrees
    ) -> CLLocationDegrees {
        var delta = destination - source
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private static func normalizedLongitude(
        _ longitude: CLLocationDegrees
    ) -> CLLocationDegrees {
        var value = longitude
        while value > 180 { value -= 360 }
        while value < -180 { value += 360 }
        return value
    }
}

/// Pure viewport policy for the quiet friend-history layer. The repository
/// keeps every footprint; only the Map content is reduced to the settled
/// viewport plus a small overscan area so panning back never reveals a blank
/// edge.
enum FriendFootprintViewportPolicy {
    static let overscanFactor = 1.5

    static func layout(
        footprints: [MapTalkFriendFootprint],
        in region: MKCoordinateRegion?,
        retaining selectedID: String?,
        overscanFactor: Double = overscanFactor
    ) -> FriendFootprintViewportLayout {
        let validFootprints = footprints.filter {
            CLLocationCoordinate2DIsValid($0.coordinate)
                && $0.coordinate.latitude.isFinite
                && $0.coordinate.longitude.isFinite
        }

        let visible: [MapTalkFriendFootprint]
        if let region {
            visible = validFootprints.filter { footprint in
                footprint.id == selectedID
                    || contains(
                        footprint.coordinate,
                        in: region,
                        overscanFactor: overscanFactor
                    )
            }
        } else {
            visible = validFootprints
        }

        return FriendFootprintViewportLayout(places: visible)
    }

    static func contains(
        _ coordinate: CLLocationCoordinate2D,
        in region: MKCoordinateRegion,
        overscanFactor: Double = overscanFactor
    ) -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate),
              coordinate.latitude.isFinite,
              coordinate.longitude.isFinite else {
            return false
        }

        let factor = max(1, overscanFactor)
        let latitudeRadius = min(90, abs(region.span.latitudeDelta) * factor / 2)
        let longitudeRadius = min(180, abs(region.span.longitudeDelta) * factor / 2)
        let latitudeDistance = abs(coordinate.latitude - region.center.latitude)
        let longitudeDistance = wrappedLongitudeDistance(
            from: coordinate.longitude,
            to: region.center.longitude
        )

        return latitudeDistance <= latitudeRadius
            && longitudeDistance <= longitudeRadius
    }

    private static func wrappedLongitudeDistance(
        from lhs: CLLocationDegrees,
        to rhs: CLLocationDegrees
    ) -> CLLocationDegrees {
        let direct = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(direct, 360 - direct)
    }
}

/// Multiple memories may resolve to the same real-world place. They stay at
/// the true coordinate instead of being fanned out; repeated taps rotate the
/// selection so every record remains reachable.
enum FriendFootprintTapSelectionPolicy {
    static let overlapDistanceMeters: CLLocationDistance = 4

    static func nextID(
        tappedID: String,
        selectedID: String?,
        visibleFootprints: [MapTalkFriendFootprint]
    ) -> String {
        guard let tapped = visibleFootprints.first(where: { $0.id == tappedID }) else {
            return tappedID
        }

        let tappedPoint = MKMapPoint(tapped.coordinate)
        let overlappingIDs = visibleFootprints.compactMap { footprint -> String? in
            let distance = tappedPoint.distance(to: MKMapPoint(footprint.coordinate))
            return distance <= overlapDistanceMeters ? footprint.id : nil
        }
        .sorted()

        guard overlappingIDs.count > 1,
              let selectedID,
              let selectedIndex = overlappingIDs.firstIndex(of: selectedID) else {
            return tappedID
        }

        return overlappingIDs[(selectedIndex + 1) % overlappingIDs.count]
    }
}

/// A map tap can also mean "stop the inertial scroll." This non-published gate
/// records camera motion without invalidating the SwiftUI tree every frame and
/// briefly withholds only compact marker buttons after movement. Normal
/// Reel, POI, and expanded friend-marker buttons remain immediately responsive.
@MainActor
final class FriendFootprintMapInteractionGate: ObservableObject {
    static let settleDelay: TimeInterval = 0.15

    private var compactTapBlockedUntil: TimeInterval = -.infinity

    func noteCameraMotion(
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        compactTapBlockedUntil = max(
            compactTapBlockedUntil,
            timestamp + Self.settleDelay
        )
    }

    func allowsCompactTap(
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        timestamp >= compactTapBlockedUntil
    }
}

extension MapTalkFriendFootprint {
    /// Feature-local preview data keeps this early visual prototype separate
    /// from the public post repositories. Seattle keeps the authored examples;
    /// Sunnyvale adds a deterministic high-density set for map exploration and
    /// rendering tests without committing hundreds of hand-written records.
    static var previewData: [MapTalkFriendFootprint] {
        let friends = PreviewData.sampleFriends
        guard friends.count >= 8 else { return [] }

        let seattle = [
            MapTalkFriendFootprint(
                id: "golden-gardens",
                placeName: "Golden Gardens",
                coordinate: CLLocationCoordinate2D(latitude: 47.6917, longitude: -122.4029),
                category: .viewpoint,
                friendIDs: [friends[0].id, friends[2].id, friends[5].id]
            ),
            MapTalkFriendFootprint(
                id: "green-lake",
                placeName: "Green Lake",
                coordinate: CLLocationCoordinate2D(latitude: 47.6803, longitude: -122.3280),
                category: .viewpoint,
                friendIDs: [friends[1].id, friends[3].id, friends[4].id, friends[7].id]
            ),
            MapTalkFriendFootprint(
                id: "discovery-park",
                placeName: "Discovery Park",
                coordinate: CLLocationCoordinate2D(latitude: 47.6573, longitude: -122.4058),
                category: .viewpoint,
                friendIDs: [friends[0].id, friends[1].id, friends[4].id, friends[6].id, friends[7].id]
            ),
            MapTalkFriendFootprint(
                id: "ballard-farmers-market",
                placeName: "Ballard Farmers Market",
                coordinate: CLLocationCoordinate2D(latitude: 47.6687, longitude: -122.3853),
                category: .market,
                friendIDs: [friends[2].id, friends[6].id]
            ),
            MapTalkFriendFootprint(
                id: "fremont-sunday-market",
                placeName: "Fremont Sunday Market",
                coordinate: CLLocationCoordinate2D(latitude: 47.6508, longitude: -122.3509),
                category: .market,
                friendIDs: [friends[0].id, friends[3].id, friends[5].id, friends[7].id]
            ),
            MapTalkFriendFootprint(
                id: "burke-museum",
                placeName: "Burke Museum",
                coordinate: CLLocationCoordinate2D(latitude: 47.6600, longitude: -122.3116),
                category: .art,
                friendIDs: [friends[1].id, friends[5].id, friends[6].id]
            ),
            MapTalkFriendFootprint(
                id: "gas-works-park",
                placeName: "Gas Works Park",
                coordinate: CLLocationCoordinate2D(latitude: 47.6456, longitude: -122.3344),
                category: .viewpoint,
                friendIDs: [friends[0].id, friends[2].id, friends[4].id, friends[6].id, friends[7].id]
            ),
            MapTalkFriendFootprint(
                id: "queen-anne-coffee",
                placeName: "Queen Anne Coffee",
                coordinate: CLLocationCoordinate2D(latitude: 47.6378, longitude: -122.3578),
                category: .coffee,
                friendIDs: [friends[2].id, friends[3].id]
            ),
            MapTalkFriendFootprint(
                id: "volunteer-park",
                placeName: "Volunteer Park Conservatory",
                coordinate: CLLocationCoordinate2D(latitude: 47.6300, longitude: -122.3144),
                category: .art,
                friendIDs: [friends[1].id, friends[4].id, friends[5].id]
            ),
            MapTalkFriendFootprint(
                id: "pike-place-market",
                placeName: "Pike Place Market",
                coordinate: CLLocationCoordinate2D(latitude: 47.6097, longitude: -122.3425),
                category: .market,
                friendIDs: [friends[0].id, friends[1].id, friends[2].id, friends[4].id, friends[6].id, friends[7].id]
            ),
            MapTalkFriendFootprint(
                id: "neumos",
                placeName: "Neumos",
                coordinate: CLLocationCoordinate2D(latitude: 47.6136, longitude: -122.3208),
                category: .nightlife,
                friendIDs: [friends[3].id, friends[5].id, friends[7].id]
            ),
            MapTalkFriendFootprint(
                id: "communion",
                placeName: "Communion",
                coordinate: CLLocationCoordinate2D(latitude: 47.6022, longitude: -122.3013),
                category: .restaurant,
                friendIDs: [friends[0].id, friends[4].id]
            ),
            MapTalkFriendFootprint(
                id: "marination-ma-kai",
                placeName: "Marination Ma Kai",
                coordinate: CLLocationCoordinate2D(latitude: 47.5894, longitude: -122.3814),
                category: .restaurant,
                friendIDs: [friends[1].id, friends[2].id, friends[6].id, friends[7].id]
            ),
            MapTalkFriendFootprint(
                id: "alki-beach",
                placeName: "Alki Beach",
                coordinate: CLLocationCoordinate2D(latitude: 47.5791, longitude: -122.4122),
                category: .viewpoint,
                friendIDs: [friends[2].id, friends[4].id, friends[5].id]
            ),
            MapTalkFriendFootprint(
                id: "beacon-hill-coffee",
                placeName: "Beacon Hill Coffee",
                coordinate: CLLocationCoordinate2D(latitude: 47.5796, longitude: -122.3114),
                category: .coffee,
                friendIDs: [friends[0].id, friends[3].id, friends[6].id]
            ),
            MapTalkFriendFootprint(
                id: "columbia-city-night-market",
                placeName: "Columbia City Night Market",
                coordinate: CLLocationCoordinate2D(latitude: 47.5598, longitude: -122.2869),
                category: .nightlife,
                friendIDs: [friends[1].id, friends[5].id]
            ),
            MapTalkFriendFootprint(
                id: "seward-park",
                placeName: "Seward Park",
                coordinate: CLLocationCoordinate2D(latitude: 47.5505, longitude: -122.2570),
                category: .viewpoint,
                friendIDs: [friends[0].id, friends[3].id, friends[5].id, friends[7].id]
            )
        ]

        return seattle + sunnyvalePreviewData(friends: friends)
    }

    private static func sunnyvalePreviewData(
        friends: [User]
    ) -> [MapTalkFriendFootprint] {
        let friendPool = Array(friends.prefix(8))
        var footprints: [MapTalkFriendFootprint] = []
        footprints.reserveCapacity(
            sunnyvaleCityPointCount
                + sunnyvaleCorridors.reduce(0) { $0 + $1.pointCount }
        )

        var cityRandom = SunnyvaleRandom(seed: 0x4D_41_50_54_41_4C_4B)
        let cityCoordinates = sunnyvaleCityFabricCoordinates(
            count: sunnyvaleCityPointCount,
            random: &cityRandom
        )
        for (index, coordinate) in cityCoordinates.enumerated() {
            let category = sunnyvaleCityCategoryPool[
                cityRandom.nextInt(upperBound: sunnyvaleCityCategoryPool.count)
            ]
            let district = nearestSunnyvaleAnchor(to: coordinate)
            footprints.append(
                MapTalkFriendFootprint(
                    id: "sunnyvale-city-\(index + 1)",
                    placeName: "\(district.name) · \(category.displayName) \(index + 1)",
                    coordinate: coordinate,
                    category: category,
                    friendIDs: sunnyvaleFriendIDs(
                        from: friendPool,
                        random: &cityRandom
                    )
                )
            )
        }

        for (corridorIndex, corridor) in sunnyvaleCorridors.enumerated() {
            var corridorRandom = SunnyvaleRandom(
                seed: 0x53_55_4E_4E_59 &+ UInt64(corridorIndex) &* 0x9E37
            )
            let coordinates = sunnyvaleCorridorCoordinates(
                corridor,
                random: &corridorRandom
            )
            let categoryPool = corridor.profile.categoryPool

            for (pointIndex, coordinate) in coordinates.enumerated() {
                let category = categoryPool[
                    corridorRandom.nextInt(upperBound: categoryPool.count)
                ]
                footprints.append(
                    MapTalkFriendFootprint(
                        id: "sunnyvale-\(corridor.id)-\(pointIndex + 1)",
                        placeName: "\(corridor.name) · \(category.displayName) \(pointIndex + 1)",
                        coordinate: coordinate,
                        category: category,
                        friendIDs: sunnyvaleFriendIDs(
                            from: friendPool,
                            random: &corridorRandom
                        )
                    )
                )
            }
        }

        return footprints
    }

    private static func sunnyvaleCityFabricCoordinates(
        count: Int,
        random: inout SunnyvaleRandom
    ) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(count)
        var attempts = 0

        while coordinates.count < count, attempts < count * 160 {
            attempts += 1
            let candidate = CLLocationCoordinate2D(
                latitude: sunnyvaleLatitudeBounds.lowerBound
                    + random.nextUnit()
                    * (sunnyvaleLatitudeBounds.upperBound
                        - sunnyvaleLatitudeBounds.lowerBound),
                longitude: sunnyvaleLongitudeBounds.lowerBound
                    + random.nextUnit()
                    * (sunnyvaleLongitudeBounds.upperBound
                        - sunnyvaleLongitudeBounds.lowerBound)
            )
            guard isInsideSunnyvalePreviewArea(candidate) else { continue }

            let candidatePoint = MKMapPoint(candidate)
            guard coordinates.allSatisfy({ existing in
                candidatePoint.distance(to: MKMapPoint(existing)) >= 82
            }) else {
                continue
            }
            coordinates.append(candidate)
        }

        // The preview polygon has ample room for the requested count. This
        // fallback keeps mock generation total even if future bounds shrink.
        while coordinates.count < count {
            let candidate = CLLocationCoordinate2D(
                latitude: sunnyvaleLatitudeBounds.lowerBound
                    + random.nextUnit()
                    * (sunnyvaleLatitudeBounds.upperBound
                        - sunnyvaleLatitudeBounds.lowerBound),
                longitude: sunnyvaleLongitudeBounds.lowerBound
                    + random.nextUnit()
                    * (sunnyvaleLongitudeBounds.upperBound
                        - sunnyvaleLongitudeBounds.lowerBound)
            )
            if isInsideSunnyvalePreviewArea(candidate) {
                coordinates.append(candidate)
            }
        }

        return coordinates
    }

    private static func sunnyvaleCorridorCoordinates(
        _ corridor: SunnyvaleCorridor,
        random: inout SunnyvaleRandom
    ) -> [CLLocationCoordinate2D] {
        let midpointLatitude = (
            corridor.start.latitude + corridor.end.latitude
        ) / 2
        let latitudeMeters = 111_320.0
        let longitudeMeters = latitudeMeters
            * max(cos(midpointLatitude * .pi / 180), 0.1)
        let north = (corridor.end.latitude - corridor.start.latitude)
            * latitudeMeters
        let east = (corridor.end.longitude - corridor.start.longitude)
            * longitudeMeters
        let length = max(hypot(north, east), 1)
        let normalNorth = -east / length
        let normalEast = north / length

        return (0..<corridor.pointCount).map { index in
            let positionJitter = (random.nextUnit() - 0.5) * 0.7
            let progress = min(
                1,
                max(
                    0,
                    (Double(index) + 0.5 + positionJitter)
                        / Double(corridor.pointCount)
                )
            )
            let base = CLLocationCoordinate2D(
                latitude: corridor.start.latitude
                    + (corridor.end.latitude - corridor.start.latitude) * progress,
                longitude: corridor.start.longitude
                    + (corridor.end.longitude - corridor.start.longitude) * progress
            )
            let crossStreetOffset = (random.nextUnit() - 0.5)
                * 2 * corridor.widthMeters
            let candidate = offsetCoordinate(
                base,
                northMeters: normalNorth * crossStreetOffset,
                eastMeters: normalEast * crossStreetOffset
            )
            return isInsideSunnyvalePreviewArea(candidate) ? candidate : base
        }
    }

    private static func sunnyvaleFriendIDs(
        from friends: [User],
        random: inout SunnyvaleRandom
    ) -> [UUID] {
        let roll = random.nextUnit()
        let friendCount: Int
        switch roll {
        case ..<0.58: friendCount = 1
        case ..<0.82: friendCount = 2
        case ..<0.93: friendCount = 3
        case ..<0.98: friendCount = 4
        default: friendCount = min(5 + random.nextInt(upperBound: 4), friends.count)
        }

        let firstIndex = random.nextInt(upperBound: friends.count)
        return (0..<friendCount).map { offset in
            friends[(firstIndex + offset * 3) % friends.count].id
        }
    }

    private static func nearestSunnyvaleAnchor(
        to coordinate: CLLocationCoordinate2D
    ) -> SunnyvaleAnchor {
        let point = MKMapPoint(coordinate)
        return sunnyvaleAnchors.min { lhs, rhs in
            point.distance(to: MKMapPoint(lhs.coordinate))
                < point.distance(to: MKMapPoint(rhs.coordinate))
        } ?? sunnyvaleAnchors[0]
    }

    private static func offsetCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        northMeters: CLLocationDistance,
        eastMeters: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        let latitudeMeters = 111_320.0
        let longitudeMeters = latitudeMeters
            * max(cos(coordinate.latitude * .pi / 180), 0.1)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + northMeters / latitudeMeters,
            longitude: coordinate.longitude + eastMeters / longitudeMeters
        )
    }

    private static func isInsideSunnyvalePreviewArea(
        _ coordinate: CLLocationCoordinate2D
    ) -> Bool {
        let x = coordinate.longitude
        let y = coordinate.latitude
        var isInside = false
        var previousIndex = sunnyvalePreviewPolygon.count - 1

        for index in sunnyvalePreviewPolygon.indices {
            let current = sunnyvalePreviewPolygon[index]
            let previous = sunnyvalePreviewPolygon[previousIndex]
            if (current.latitude > y) != (previous.latitude > y) {
                let boundaryLongitude = (previous.longitude - current.longitude)
                    * (y - current.latitude)
                    / (previous.latitude - current.latitude)
                    + current.longitude
                if x < boundaryLongitude {
                    isInside.toggle()
                }
            }
            previousIndex = index
        }

        return isInside
    }

    private struct SunnyvaleRandom {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func nextUnit() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            return Double(value >> 11) / 9_007_199_254_740_992
        }

        mutating func nextInt(upperBound: Int) -> Int {
            guard upperBound > 1 else { return 0 }
            return min(Int(nextUnit() * Double(upperBound)), upperBound - 1)
        }
    }

    private enum SunnyvaleCorridorProfile {
        case retail
        case neighborhood
        case mixed

        var categoryPool: [POICategory] {
            switch self {
            case .retail:
                return [
                    .restaurant, .restaurant, .restaurant, .restaurant,
                    .coffee, .coffee, .coffee,
                    .market, .market,
                    .nightlife, .art, .other
                ]
            case .neighborhood:
                return [
                    .coffee, .coffee, .coffee,
                    .restaurant, .restaurant, .restaurant,
                    .viewpoint, .viewpoint,
                    .art, .art, .market, .other
                ]
            case .mixed:
                return [
                    .restaurant, .restaurant, .restaurant,
                    .coffee, .coffee,
                    .market, .market,
                    .viewpoint, .art, .nightlife, .other, .other
                ]
            }
        }
    }

    private struct SunnyvaleCorridor {
        let id: String
        let name: String
        let start: CLLocationCoordinate2D
        let end: CLLocationCoordinate2D
        let pointCount: Int
        let widthMeters: CLLocationDistance
        let profile: SunnyvaleCorridorProfile
    }

    private struct SunnyvaleAnchor {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    private static let sunnyvaleCityPointCount = 190

    private static let sunnyvaleLatitudeBounds = 37.336...37.422
    private static let sunnyvaleLongitudeBounds = -122.079 ... -121.990

    private static let sunnyvalePreviewPolygon = [
        CLLocationCoordinate2D(latitude: 37.421, longitude: -122.055),
        CLLocationCoordinate2D(latitude: 37.421, longitude: -121.995),
        CLLocationCoordinate2D(latitude: 37.389, longitude: -121.990),
        CLLocationCoordinate2D(latitude: 37.343, longitude: -121.994),
        CLLocationCoordinate2D(latitude: 37.336, longitude: -122.048),
        CLLocationCoordinate2D(latitude: 37.345, longitude: -122.073),
        CLLocationCoordinate2D(latitude: 37.389, longitude: -122.079)
    ]

    private static let sunnyvaleCityCategoryPool: [POICategory] = [
        .restaurant, .restaurant, .restaurant, .restaurant,
        .coffee, .coffee, .coffee, .coffee,
        .market, .market,
        .art, .art,
        .viewpoint, .viewpoint,
        .nightlife,
        .other, .other, .other
    ]

    private static let sunnyvaleCorridors: [SunnyvaleCorridor] = [
        SunnyvaleCorridor(
            id: "el-camino",
            name: "El Camino Real",
            start: CLLocationCoordinate2D(latitude: 37.398, longitude: -122.071),
            end: CLLocationCoordinate2D(latitude: 37.351, longitude: -121.996),
            pointCount: 26,
            widthMeters: 145,
            profile: .retail
        ),
        SunnyvaleCorridor(
            id: "mathilda",
            name: "Mathilda Avenue",
            start: CLLocationCoordinate2D(latitude: 37.417, longitude: -122.019),
            end: CLLocationCoordinate2D(latitude: 37.345, longitude: -122.034),
            pointCount: 18,
            widthMeters: 115,
            profile: .mixed
        ),
        SunnyvaleCorridor(
            id: "fair-oaks",
            name: "Fair Oaks Avenue",
            start: CLLocationCoordinate2D(latitude: 37.410, longitude: -122.007),
            end: CLLocationCoordinate2D(latitude: 37.347, longitude: -122.018),
            pointCount: 16,
            widthMeters: 105,
            profile: .neighborhood
        ),
        SunnyvaleCorridor(
            id: "sunnyvale-avenue",
            name: "Sunnyvale Avenue",
            start: CLLocationCoordinate2D(latitude: 37.398, longitude: -122.030),
            end: CLLocationCoordinate2D(latitude: 37.346, longitude: -122.028),
            pointCount: 14,
            widthMeters: 95,
            profile: .retail
        ),
        SunnyvaleCorridor(
            id: "wolfe",
            name: "Wolfe Road",
            start: CLLocationCoordinate2D(latitude: 37.397, longitude: -121.999),
            end: CLLocationCoordinate2D(latitude: 37.343, longitude: -122.014),
            pointCount: 18,
            widthMeters: 115,
            profile: .mixed
        ),
        SunnyvaleCorridor(
            id: "hollenbeck",
            name: "Hollenbeck Avenue",
            start: CLLocationCoordinate2D(latitude: 37.382, longitude: -122.049),
            end: CLLocationCoordinate2D(latitude: 37.341, longitude: -122.053),
            pointCount: 14,
            widthMeters: 90,
            profile: .neighborhood
        ),
        SunnyvaleCorridor(
            id: "fremont",
            name: "Fremont Avenue",
            start: CLLocationCoordinate2D(latitude: 37.352, longitude: -122.067),
            end: CLLocationCoordinate2D(latitude: 37.352, longitude: -121.997),
            pointCount: 18,
            widthMeters: 105,
            profile: .neighborhood
        ),
        SunnyvaleCorridor(
            id: "maude",
            name: "Maude Avenue",
            start: CLLocationCoordinate2D(latitude: 37.389, longitude: -122.064),
            end: CLLocationCoordinate2D(latitude: 37.390, longitude: -121.996),
            pointCount: 16,
            widthMeters: 110,
            profile: .mixed
        ),
        SunnyvaleCorridor(
            id: "tasman",
            name: "Tasman Drive",
            start: CLLocationCoordinate2D(latitude: 37.405, longitude: -122.054),
            end: CLLocationCoordinate2D(latitude: 37.404, longitude: -121.997),
            pointCount: 18,
            widthMeters: 125,
            profile: .mixed
        ),
        SunnyvaleCorridor(
            id: "lawrence",
            name: "Lawrence Expressway",
            start: CLLocationCoordinate2D(latitude: 37.406, longitude: -121.996),
            end: CLLocationCoordinate2D(latitude: 37.349, longitude: -121.998),
            pointCount: 14,
            widthMeters: 125,
            profile: .mixed
        )
    ]

    private static let sunnyvaleAnchors: [SunnyvaleAnchor] = [
        SunnyvaleAnchor(
            id: "downtown",
            name: "Downtown Sunnyvale",
            coordinate: CLLocationCoordinate2D(latitude: 37.3769, longitude: -122.0300)
        ),
        SunnyvaleAnchor(
            id: "heritage",
            name: "Heritage District",
            coordinate: CLLocationCoordinate2D(latitude: 37.3714, longitude: -122.0380)
        ),
        SunnyvaleAnchor(
            id: "washington-park",
            name: "Washington Park",
            coordinate: CLLocationCoordinate2D(latitude: 37.3742, longitude: -122.0486)
        ),
        SunnyvaleAnchor(
            id: "las-palmas",
            name: "Las Palmas",
            coordinate: CLLocationCoordinate2D(latitude: 37.3601, longitude: -122.0373)
        ),
        SunnyvaleAnchor(
            id: "baylands",
            name: "Baylands",
            coordinate: CLLocationCoordinate2D(latitude: 37.4141, longitude: -122.0162)
        ),
        SunnyvaleAnchor(
            id: "lakewood",
            name: "Lakewood",
            coordinate: CLLocationCoordinate2D(latitude: 37.3927, longitude: -122.0061)
        ),
        SunnyvaleAnchor(
            id: "seven-seas",
            name: "Seven Seas",
            coordinate: CLLocationCoordinate2D(latitude: 37.4040, longitude: -122.0126)
        ),
        SunnyvaleAnchor(
            id: "fair-oaks",
            name: "Fair Oaks",
            coordinate: CLLocationCoordinate2D(latitude: 37.3810, longitude: -122.0141)
        ),
        SunnyvaleAnchor(
            id: "ponderosa",
            name: "Ponderosa",
            coordinate: CLLocationCoordinate2D(latitude: 37.3634, longitude: -122.0044)
        ),
        SunnyvaleAnchor(
            id: "ortega",
            name: "Ortega",
            coordinate: CLLocationCoordinate2D(latitude: 37.3483, longitude: -122.0410)
        ),
        SunnyvaleAnchor(
            id: "serra",
            name: "Serra",
            coordinate: CLLocationCoordinate2D(latitude: 37.3561, longitude: -122.0540)
        ),
        SunnyvaleAnchor(
            id: "cherry-chase",
            name: "Cherry Chase",
            coordinate: CLLocationCoordinate2D(latitude: 37.3533, longitude: -122.0562)
        ),
        SunnyvaleAnchor(
            id: "raynor",
            name: "Raynor",
            coordinate: CLLocationCoordinate2D(latitude: 37.3508, longitude: -122.0620)
        ),
        SunnyvaleAnchor(
            id: "community-center",
            name: "Community Center",
            coordinate: CLLocationCoordinate2D(latitude: 37.3574, longitude: -122.0250)
        ),
        SunnyvaleAnchor(
            id: "braly",
            name: "Braly",
            coordinate: CLLocationCoordinate2D(latitude: 37.3550, longitude: -122.0121)
        ),
        SunnyvaleAnchor(
            id: "birdland",
            name: "Birdland",
            coordinate: CLLocationCoordinate2D(latitude: 37.3462, longitude: -122.0180)
        ),
        SunnyvaleAnchor(
            id: "peery",
            name: "Peery Park",
            coordinate: CLLocationCoordinate2D(latitude: 37.3880, longitude: -122.0450)
        ),
        SunnyvaleAnchor(
            id: "maude",
            name: "Maude",
            coordinate: CLLocationCoordinate2D(latitude: 37.3890, longitude: -122.0290)
        )
    ]
}

struct FriendFootprintOverlay: MapContent {
    let footprints: [MapTalkFriendFootprint]
    let selectedID: String?
    let visibility: FriendFootprintScreenVisibility
    let allowsCompactActivation: () -> Bool
    let onTap: (MapTalkFriendFootprint) -> Void

    var body: some MapContent {
        let visiblePlaces = footprints.filter { visibility.placeIDs.contains($0.id) }

        ForEach(visiblePlaces) { footprint in
            Annotation("", coordinate: footprint.coordinate) {
                let isExpanded = visibility.expandedPlaceIDs.contains(footprint.id)

                ZStack {
                    FriendVisitedPlaceMarker(
                        category: footprint.category,
                        friendCount: footprint.friendIDs.count,
                        isExpanded: isExpanded,
                        isSelected: selectedID == footprint.id,
                        densityStyle: visibility.densityStyle
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                    Button {
                        guard isExpanded || allowsCompactActivation() else { return }
                        onTap(footprint)
                    } label: {
                        Circle()
                            .fill(Color.black.opacity(0.001))
                            .frame(
                                width: isExpanded
                                    ? 44
                                    : visibility.densityStyle.compactControlSize,
                                height: isExpanded
                                    ? 44
                                    : visibility.densityStyle.compactControlSize
                            )
                    }
                    .buttonStyle(
                        ExactCircularMapButtonStyle(
                            diameter: isExpanded
                                ? 44
                                : visibility.densityStyle.compactControlSize
                        )
                    )
                    .accessibilityLabel(footprint.placeName)
                    .accessibilityValue("Visited by \(footprint.friendIDs.count) people")
                    .accessibilityHint("Open place history")
                    .accessibilityIdentifier(
                        "maptalk.friend-place.\(isExpanded ? "expanded" : "compact").\(footprint.id)"
                    )
                }
                .zIndex(selectedID == footprint.id ? 2 : (isExpanded ? 1 : 0))
            }
        }
    }
}

/// SwiftUI deliberately adds forgiveness around small controls. That is useful
/// in ordinary UI, but on a dense map it makes nearby empty space feel tappable.
/// Keep a real Button for semantics while accepting its action only when the
/// reported tap actually lands inside this marker's circular control.
private struct ExactCircularMapButtonStyle: PrimitiveButtonStyle {
    let diameter: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: diameter, height: diameter)
            .contentShape(.interaction, Circle())
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { value in
                        let radius = diameter / 2
                        let offsetX = value.location.x - radius
                        let offsetY = value.location.y - radius
                        guard hypot(offsetX, offsetY) <= radius else { return }
                        configuration.trigger()
                    }
            )
    }
}

/// Compact circles make friend history legible without competing with the map.
/// A place becomes the familiar MapTalk diamond only when it is promoted to an
/// interactive detail entrance. Expanded history stays deliberately smaller
/// than a published story marker.
private struct FriendVisitedPlaceMarker: View {
    let category: POICategory
    let friendCount: Int
    let isExpanded: Bool
    let isSelected: Bool
    let densityStyle: FriendFootprintDensityStyle

    var body: some View {
        ZStack {
            if showsDetail {
                expandedMarker
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else {
                compactMarker
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .frame(
            width: showsDetail ? 44 : 28,
            height: showsDetail ? 44 : 28
        )
        .contentShape(Circle())
        .animation(.snappy(duration: 0.18, extraBounce: 0), value: isExpanded)
        .animation(.snappy(duration: 0.17, extraBounce: 0), value: isSelected)
        .animation(.easeOut(duration: 0.14), value: densityStyle)
    }

    private var expandedMarker: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedDiamond(cornerRadius: isSelected ? 5 : 4.5)
                    .stroke(
                        Color.white.opacity(isSelected ? 0.92 : 0.62),
                        lineWidth: isSelected ? 1.8 : 1.2
                    )
                    .frame(width: markerSize + 5, height: markerSize + 5)

                RoundedDiamond(cornerRadius: isSelected ? 4.5 : 4)
                    .fill(markerGradient)
                    .frame(width: markerSize, height: markerSize)

                RoundedDiamond(cornerRadius: isSelected ? 4.5 : 4)
                    .stroke(Color.white.opacity(0.34), lineWidth: 0.8)
                    .frame(width: markerSize, height: markerSize)

                Image(systemName: category.symbolName)
                    .font(.system(size: isSelected ? 12 : 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            }

            if friendCount > 1 {
                Text(friendCount > 9 ? "9+" : "\(friendCount)")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 15, minHeight: 15)
                    .padding(.horizontal, friendCount > 9 ? 1.5 : 0)
                    .background(Color.black.opacity(0.82), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    }
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: 38, height: 38)
        .shadow(color: Color.black.opacity(0.14), radius: 3, y: 2)
    }

    private var compactMarker: some View {
        let size = densityStyle.compactMarkerSize

        return ZStack {
            Circle()
                .fill(compactColor.opacity(densityStyle.compactMarkerOpacity))

            Circle()
                .stroke(
                    Color.white.opacity(densityStyle.compactMarkerStrokeOpacity),
                    lineWidth: densityStyle.compactMarkerStrokeWidth
                )
        }
        .frame(width: size, height: size)
    }

    private var markerSize: CGFloat {
        isSelected ? 32 : 28
    }

    private var showsDetail: Bool {
        isExpanded || isSelected
    }

    private var markerGradient: LinearGradient {
        LinearGradient(
            colors: category.markerGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var compactColor: Color {
        category.markerGradientColors.first ?? category.accentColor
    }

}
