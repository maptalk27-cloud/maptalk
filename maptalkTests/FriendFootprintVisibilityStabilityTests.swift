import MapKit
import Testing
@testable import maptalk

@MainActor
struct FriendFootprintVisibilityStabilityTests {
    @Test
    func collisionBoundaryRetainsVisiblePlaceButWaitsToRevealHiddenPlace() {
        let place = FriendFootprintProjectedPlace(
            id: "history",
            point: CGPoint(x: 172, y: 420),
            friendCount: 2
        )
        let retained = visibility(for: [place], previousIDs: [place.id])
        let hidden = visibility(for: [place])

        #expect(retained.placeIDs.contains(place.id))
        #expect(hidden.placeIDs.isEmpty)

        let tooClose = FriendFootprintProjectedPlace(
            id: place.id,
            point: CGPoint(x: 165, y: 420),
            friendCount: place.friendCount
        )
        #expect(visibility(for: [tooClose], previousIDs: [place.id]).placeIDs.isEmpty)

        let clear = FriendFootprintProjectedPlace(
            id: place.id,
            point: CGPoint(x: 179, y: 420),
            friendCount: place.friendCount
        )
        #expect(visibility(for: [clear]).placeIDs.contains(place.id))
    }

    @Test
    func selectedPlaceKeepsItsExpandedAnchorThroughCollision() {
        let place = FriendFootprintProjectedPlace(
            id: "selected",
            point: CGPoint(x: 100, y: 420),
            friendCount: 1
        )
        let result = visibility(for: [place], selectedID: place.id)

        #expect(result.placeIDs == [place.id])
        #expect(result.expandedPlaceIDs == [place.id])
        #expect(FriendFootprintDensityStyle.dense.compactControlSize == 16)
    }

    @Test
    func densityTierChangePreservesRepresentativeWithinNewBudget() {
        let candidates = (0..<60).map { index in
            FriendFootprintProjectedPlace(
                id: "place-\(index)",
                point: CGPoint(x: 60, y: 200),
                friendCount: index
            )
        }
        let canvas = CGSize(width: 200, height: 600)
        let result = FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: candidates,
            reservedPoints: [],
            canvasSize: canvas,
            topChromeBottom: 100,
            selectedID: nil,
            previouslyVisibleIDs: ["place-0"],
            previousDensityStyle: .dense
        )

        #expect(result.densityStyle == .medium)
        #expect(result.placeIDs == ["place-0"])
        #expect(result.placeIDs.count <= FriendFootprintScreenLayoutPolicy.visibleMarkerCapacity(
            canvasSize: canvas,
            topChromeBottom: 100,
            densityStyle: result.densityStyle
        ))
    }

    @Test
    func screenEdgeUsesSmallRetentionMarginWithoutGrowingNewEntryArea() {
        let place = FriendFootprintProjectedPlace(
            id: "edge",
            point: CGPoint(x: -24, y: 420),
            friendCount: 1
        )
        #expect(visibility(for: [place], previousIDs: [place.id]).placeIDs.contains(place.id))
        #expect(visibility(for: [place]).placeIDs.isEmpty)

        let outside = FriendFootprintProjectedPlace(
            id: place.id,
            point: CGPoint(x: -33, y: 420),
            friendCount: place.friendCount
        )
        #expect(visibility(for: [outside], previousIDs: [place.id]).placeIDs.isEmpty)
    }

    private func visibility(
        for places: [FriendFootprintProjectedPlace],
        previousIDs: Set<String> = [],
        selectedID: String? = nil
    ) -> FriendFootprintScreenVisibility {
        FriendFootprintScreenLayoutPolicy.visibility(
            projectedPlaces: places,
            reservedPoints: [CGPoint(x: 100, y: 420)],
            canvasSize: CGSize(width: 393, height: 852),
            topChromeBottom: 220,
            selectedID: selectedID,
            previouslyVisibleIDs: previousIDs
        )
    }
}
