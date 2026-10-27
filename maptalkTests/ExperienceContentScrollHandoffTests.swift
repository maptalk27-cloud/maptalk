import Testing
import UIKit
@testable import maptalk

@MainActor
struct ExperienceContentScrollHandoffTests {
    @Test
    func overflowChangesOnlyThePanelsOwnScrolling() {
        let fixture = Fixture()
        let panel = UIScrollView(frame: fixture.window.bounds)
        let gallery = UIScrollView(frame: panel.bounds)
        fixture.pager.addSubview(panel)
        panel.addSubview(gallery)
        let content = UIView()
        panel.addSubview(content)
        let probe = ExperienceContentScrollHandoff.ProbeView()
        content.addSubview(probe)

        for isScrollable in [false, true, false] {
            probe.isScrollable = isScrollable
            probe.refreshAncestor()
            #expect(panel.isScrollEnabled == isScrollable)
            #expect(gallery.isScrollEnabled)
            #expect(fixture.pager.isScrollEnabled)
        }
        probe.detach()
        #expect(panel.isScrollEnabled)
        probe.detach()
        #expect(panel.isScrollEnabled)
    }

    @Test
    func initiallyDisabledPanelStaysDisabled() {
        let fixture = Fixture()
        let panel = UIScrollView(frame: fixture.window.bounds)
        panel.isScrollEnabled = false
        fixture.pager.addSubview(panel)
        let probe = ExperienceContentScrollHandoff.ProbeView()
        panel.addSubview(probe)
        probe.isScrollable = true
        probe.refreshAncestor()
        #expect(!panel.isScrollEnabled)
        probe.detach()
        #expect(!panel.isScrollEnabled)
    }

    @Test
    func reparentingRestoresOldPanelAndWindowRemovalRestoresNewPanel() {
        let fixture = Fixture()
        let first = UIScrollView(frame: fixture.window.bounds)
        let second = UIScrollView(frame: fixture.window.bounds)
        fixture.pager.addSubview(first)
        fixture.pager.addSubview(second)
        let probe = ExperienceContentScrollHandoff.ProbeView()
        first.addSubview(probe)
        probe.refreshAncestor()
        #expect(!first.isScrollEnabled)

        second.addSubview(probe)
        probe.refreshAncestor()
        #expect(first.isScrollEnabled)
        #expect(!second.isScrollEnabled)

        second.removeFromSuperview()
        #expect(second.isScrollEnabled)
        probe.detach()
        #expect(second.isScrollEnabled)
    }

    @Test
    func directPageCollectionAncestryIsIgnored() {
        let fixture = Fixture()
        let probe = ExperienceContentScrollHandoff.ProbeView()
        fixture.pager.addSubview(probe)
        probe.refreshAncestor()
        #expect(fixture.pager.isScrollEnabled)
        probe.detach()
        #expect(fixture.pager.isScrollEnabled)
    }

    private final class Fixture {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 778))
        let pager: UICollectionView

        init() {
            let layout = UICollectionViewFlowLayout()
            layout.scrollDirection = .horizontal
            pager = UICollectionView(frame: window.bounds, collectionViewLayout: layout)
            window.addSubview(pager)
        }
    }
}
