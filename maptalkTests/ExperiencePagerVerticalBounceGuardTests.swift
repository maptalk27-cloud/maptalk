import Testing
import UIKit
@testable import maptalk

@MainActor
struct ExperiencePagerVerticalBounceGuardTests {
    @Test
    func disablesOnlyEnclosingPagersVerticalBounce() {
        let fixture = Fixture(horizontal: true)
        let content = UIScrollView(frame: fixture.collection.bounds)
        content.bouncesVertically = true
        content.alwaysBounceVertical = true
        fixture.collection.addSubview(content)
        let probe = ExperiencePagerVerticalBounceGuard.ProbeView()
        content.addSubview(probe)
        probe.refreshAncestor()

        #expect(!fixture.collection.bouncesVertically)
        #expect(!fixture.collection.alwaysBounceVertical)
        #expect(fixture.collection.bouncesHorizontally)
        #expect(fixture.collection.isScrollEnabled)
        #expect(content.bouncesVertically)
        #expect(content.alwaysBounceVertical)
        #expect(content.isScrollEnabled)
        probe.detach()
        #expect(fixture.collection.bouncesVertically)
        #expect(fixture.collection.alwaysBounceVertical)
    }

    @Test
    func neighboringPagesRestoreOriginalPolicyOnlyAfterLastOwnerLeaves() {
        let fixture = Fixture(horizontal: true)
        fixture.collection.bouncesVertically = false
        let first = ExperiencePagerVerticalBounceGuard.ProbeView()
        let second = ExperiencePagerVerticalBounceGuard.ProbeView()
        fixture.collection.addSubview(first)
        fixture.collection.addSubview(second)
        first.refreshAncestor()
        second.refreshAncestor()
        first.refreshAncestor() // Layout/update must not acquire another lease.

        first.detach()
        #expect(!fixture.collection.alwaysBounceVertical)
        second.detach()
        #expect(!fixture.collection.bouncesVertically) // Originally false.
        #expect(fixture.collection.alwaysBounceVertical)
        second.detach() // Repeated removal is harmless.
        #expect(fixture.collection.alwaysBounceVertical)
    }

    @Test
    func reparentingRestoresOldPagerAndDoesNotChangeVerticalCollections() {
        let horizontal = Fixture(horizontal: true)
        let vertical = Fixture(horizontal: false)
        let probe = ExperiencePagerVerticalBounceGuard.ProbeView()
        horizontal.collection.addSubview(probe)
        probe.refreshAncestor()
        #expect(!horizontal.collection.bouncesVertically)

        vertical.collection.addSubview(probe)
        probe.refreshAncestor()
        #expect(horizontal.collection.bouncesVertically)
        #expect(horizontal.collection.alwaysBounceVertical)
        #expect(vertical.collection.bouncesVertically)
        #expect(vertical.collection.alwaysBounceVertical)
        probe.detach()
    }

    private final class Fixture {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        let collection: UICollectionView

        init(horizontal: Bool) {
            let size = horizontal ? CGSize(width: 960, height: 600) : CGSize(width: 320, height: 1800)
            collection = UICollectionView(frame: window.bounds, collectionViewLayout: UICollectionViewFlowLayout())
            collection.bouncesVertically = true
            collection.alwaysBounceVertical = true
            collection.bouncesHorizontally = true
            window.addSubview(collection)
            collection.layoutIfNeeded()
            // This empty fixture has no data source to compute a content size.
            collection.contentSize = size
        }
    }
}
