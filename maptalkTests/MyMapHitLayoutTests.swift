import CoreGraphics
import Foundation
import Testing
@testable import maptalk

struct MyMapHitLayoutTests {
    @Test
    func overlapUsesScreenDistanceAndPreservesStackOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(MyMapHitLayout.group([
            marker(a, x: 0), marker(b, x: 34), marker(c, x: 100)
        ]) == [[a, b], [c]])
    }

    @Test
    func movingCameraThrottlesMembershipButFinalRefreshIsImmediate() {
        let a = UUID(), b = UUID()
        var layout = MyMapHitLayout()
        #expect(layout.groups(for: [marker(a, x: 0), marker(b, x: 100)], at: 1) == [[a], [b]])
        let zoomed = [marker(a, x: 0), marker(b, x: 20)]
        #expect(layout.groups(for: zoomed, at: 1.01) == [[a], [b]])
        layout.invalidate()
        #expect(layout.groups(for: zoomed, at: 1.02) == [[a, b]])
    }

    @Test
    func splitStacksNeverLeaveATargetInTheGapAndMovingStacksRegroupOnSchedule() {
        let a = UUID(), b = UUID()
        var layout = MyMapHitLayout()
        _ = layout.groups(for: [marker(a, x: 0), marker(b, x: 20)], at: 1)
        #expect(layout.groups(for: [marker(a, x: 0), marker(b, x: 100)], at: 1.01) == [[a], [b]])
        _ = layout.groups(for: [marker(a, x: 0), marker(b, x: 100)], at: 1.1)
        #expect(layout.groups(for: [marker(a, x: 0), marker(b, x: 20)], at: 1.11) == [[a], [b]])
        #expect(layout.groups(for: [marker(a, x: 0), marker(b, x: 20)], at: 1.2) == [[a, b]])
    }

    @Test
    func organizerAndNewlyVisibleMarkersDoNotWaitForThrottle() {
        let a = UUID(), b = UUID(), c = UUID()
        var layout = MyMapHitLayout()
        _ = layout.groups(for: [marker(a, x: 0), marker(b, x: 20)], at: 1)
        #expect(layout.groups(for: [marker(a, x: 0), marker(b, x: 100)], at: 1.01,
            exact: true) == [[a], [b]])
        #expect(layout.groups(for: [marker(a, x: 0), marker(b, x: 100), marker(c, x: 110)],
            at: 1.02) == [[a], [b, c]])
    }

    private func marker(_ id: UUID, x: CGFloat) -> MyMapHitLayout.Marker {
        .init(id: id, point: CGPoint(x: x, y: 0))
    }
}
