import CoreGraphics
import Testing
@testable import maptalk

@MainActor
struct PostMediaLayoutReferenceTests {
    @Test
    func resolvedCompactViewportWinsOverTransitionalMeasurement() {
        let compact = CGSize(width: 393, height: 402)
        let openingFrame = CGSize(width: 393, height: 820)
        #expect(PostMediaLayoutReference.resolvedCardSize(
            viewport: compact, recorded: openingFrame) == compact)
        // An expanded-first or recreated page needs no prior measurement.
        #expect(PostMediaLayoutReference.resolvedCardSize(
            viewport: compact, recorded: nil) == compact)
    }

    @Test
    func newHostDimensionsReplaceOldReferenceWithoutTraitInvalidation() {
        let portrait = CGSize(width: 393, height: 402)
        let landscape = CGSize(width: 759, height: 196)
        #expect(PostMediaLayoutReference.resolvedCardSize(
            viewport: landscape, recorded: portrait) == landscape)
    }

    @Test
    func unresolvedOrInvalidHostKeepsValidLegacyMeasurement() {
        let compact = CGSize(width: 393, height: 402)
        #expect(PostMediaLayoutReference.resolvedCardSize(
            viewport: .zero, recorded: compact) == compact)
        #expect(PostMediaLayoutReference.resolvedCardSize(
            viewport: CGSize(width: CGFloat.infinity, height: 402), recorded: compact) == compact)
        #expect(PostMediaLayoutReference.resolvedCardSize(
            viewport: nil, recorded: CGSize(width: 393, height: CGFloat.nan)) == nil)
    }
}
