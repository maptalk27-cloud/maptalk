import SwiftUI

/// Refined is the adopted Post layout. Earlier directions remain available in
/// the debug comparison screen; POI and single-video cards keep their own UI.
enum PostSheetDesign: String, CaseIterable {
    case original, refined, editorial, notebook
}

private struct PostSheetDesignKey: EnvironmentKey {
    static let defaultValue: PostSheetDesign = .refined
}

extension EnvironmentValues {
    var postSheetDesign: PostSheetDesign {
        get { self[PostSheetDesignKey.self] }
        set { self[PostSheetDesignKey.self] = newValue }
    }
}

nonisolated enum PostEditorialRole {
    case author, caption, photos, actions
}

private nonisolated struct PostEditorialRoleKey: LayoutValueKey {
    static let defaultValue: PostEditorialRole = .caption
}

extension View {
    func postEditorialRole(_ role: PostEditorialRole) -> some View {
        layoutValue(key: PostEditorialRoleKey.self, value: role)
    }
}

/// One page, rather than an avatar gutter plus a miniature card. Author and
/// actions own their natural height; the photo spread uses the remaining space.
struct PostEditorialPageLayout: Layout {
    let isCompact: Bool
    let referenceHeight: CGFloat?
    let previewCaptionHeight: CGFloat
    private let spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measurement = measure(
            proposal: ProposedViewSize(width: bounds.width, height: isCompact ? bounds.height : nil),
            subviews: subviews
        )
        let hasPhotos = subviews.contains { $0[PostEditorialRoleKey.self] == .photos }
        var y = bounds.minY
        for index in subviews.indices {
            if index > 0 { y += spacing }
            let height = measurement.heights[index]
            switch subviews[index][PostEditorialRoleKey.self] {
            case .caption where !hasPhotos:
                // A short note can breathe without looking like a missing photo.
                let remaining = measurement.heights.dropFirst(index + 1).reduce(0, +)
                    + spacing * CGFloat(subviews.count - index - 1)
                y += max(0, (bounds.maxY - remaining - y - height) / 2)
            case .actions:
                y = max(y, bounds.maxY - height)
            default:
                break
            }
            subviews[index].place(
                at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: height)
            )
            y += height
        }
    }

    private struct Measurement {
        let size: CGSize
        let heights: [CGFloat]
    }

    private func measure(proposal: ProposedViewSize, subviews: Subviews) -> Measurement {
        let width = finite(proposal.width) ?? 320
        var heights = Array(repeating: CGFloat.zero, count: subviews.count)
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let caption = subviews.firstIndex { $0[PostEditorialRoleKey.self] == .caption }
        let photos = subviews.firstIndex { $0[PostEditorialRoleKey.self] == .photos }
        for index in subviews.indices {
            let role = subviews[index][PostEditorialRoleKey.self]
            if role == .author || role == .actions {
                heights[index] = finite(subviews[index].sizeThatFits(.init(width: width, height: nil)).height) ?? 0
            }
        }
        let chromeHeight = heights.reduce(0, +) + gaps
        let viewportHeight = isCompact ? finite(proposal.height) : finite(referenceHeight)
        let captionNaturalHeight = caption.map {
            finite(subviews[$0].sizeThatFits(.init(width: width, height: nil)).height) ?? 0
        } ?? 0
        let captionPreviewHeight = caption.map {
            min(previewCaptionHeight,
                finite(subviews[$0].sizeThatFits(.init(width: width, height: previewCaptionHeight)).height) ?? 0)
        } ?? 0

        if let photos {
            // Preserve this same spread on expansion; expanding reveals prose,
            // not a differently sized set of thumbnails. Tap opens all originals.
            let available = viewportHeight.map { max(0, $0 - chromeHeight - captionPreviewHeight) }
            heights[photos] = min(width * 0.82, available ?? width * 0.64)
        }
        if let caption {
            if isCompact {
                let budget = viewportHeight.map { max(0, $0 - chromeHeight - (photos.map { heights[$0] } ?? 0)) }
                let limit = photos == nil ? budget : min(budget ?? previewCaptionHeight, previewCaptionHeight)
                heights[caption] = finite(subviews[caption].sizeThatFits(.init(width: width, height: limit)).height) ?? 0
                if let limit { heights[caption] = min(heights[caption], limit) }
            } else {
                heights[caption] = captionNaturalHeight
            }
        }
        let naturalHeight = heights.reduce(0, +) + gaps
        return Measurement(size: CGSize(width: width, height: max(naturalHeight, viewportHeight ?? 0)),
                           heights: heights)
    }

    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}

/// A single photo spread. No nested horizontal paging competing with Posts.
/// Every count fills the same rectangle; only its internal composition changes.
struct PostEditorialPhotoLayout: Layout {
    private let spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = dimension(proposal.width, fallback: 320)
        return CGSize(width: width, height: dimension(proposal.height, fallback: width * 0.64))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(in: bounds.size, count: subviews.count)
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(in size: CGSize, count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let gap = min(spacing, size.width / 3, size.height / 3)
        let halfWidth = max(0, (size.width - gap) / 2)
        let halfHeight = max(0, (size.height - gap) / 2)
        if count == 1 { return [CGRect(origin: .zero, size: size)] }
        if count == 2 {
            return (0..<2).map { CGRect(x: CGFloat($0) * (halfWidth + gap), y: 0, width: halfWidth, height: size.height) }
        }
        if count == 3 {
            let leadWidth = (size.width - gap) * 0.64
            let trailingWidth = max(0, size.width - leadWidth - gap)
            return [CGRect(x: 0, y: 0, width: leadWidth, height: size.height),
                    CGRect(x: leadWidth + gap, y: 0, width: trailingWidth, height: halfHeight),
                    CGRect(x: leadWidth + gap, y: halfHeight + gap, width: trailingWidth, height: halfHeight)]
        }
        if count == 5 {
            let thirdWidth = max(0, (size.width - gap * 2) / 3)
            return (0..<2).map { CGRect(x: CGFloat($0) * (halfWidth + gap), y: 0, width: halfWidth, height: halfHeight) }
                + (0..<3).map { CGRect(x: CGFloat($0) * (thirdWidth + gap), y: halfHeight + gap, width: thirdWidth, height: halfHeight) }
        }
        let columns = count == 4 ? 2 : 3
        let rows = (count + columns - 1) / columns
        let tileWidth = max(0, (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let tileHeight = max(0, (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
        return (0..<count).map {
            CGRect(x: CGFloat($0 % columns) * (tileWidth + gap),
                   y: CGFloat($0 / columns) * (tileHeight + gap), width: tileWidth, height: tileHeight)
        }
    }

    private func dimension(_ value: CGFloat?, fallback: CGFloat) -> CGFloat {
        guard let value, value.isFinite else { return fallback }
        return max(0, value)
    }
}

/// The note variant deliberately does not stretch photos to fill the sheet.
/// The spare room belongs to prose; the same photograph sizes survive expansion.
struct PostNotebookPageLayout: Layout {
    let isCompact: Bool
    let referenceHeight: CGFloat?
    let minimumCaptionHeight: CGFloat
    private let spacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measurement = measure(.init(width: bounds.width, height: isCompact ? bounds.height : nil), subviews: subviews)
        let spare = max(0, bounds.height - measurement.contentHeight)
        var y = bounds.minY
        var didPlaceBody = false
        for index in subviews.indices {
            if index > 0 { y += spacing }
            let role = subviews[index][PostEditorialRoleKey.self]
            if !didPlaceBody, role == .caption || role == .photos {
                // A little breathing room, not a vertically centered quote card.
                y += min(32, spare * 0.28)
                didPlaceBody = true
            }
            let height = measurement.heights[index]
            if role == .actions { y = max(y, bounds.maxY - height) }
            subviews[index].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                                 proposal: .init(width: bounds.width, height: height))
            y += height
        }
    }

    private struct Measurement {
        let size: CGSize
        let heights: [CGFloat]
        let contentHeight: CGFloat
    }

    private func measure(_ proposal: ProposedViewSize, subviews: Subviews) -> Measurement {
        let width = finite(proposal.width) ?? 320
        let viewport = isCompact ? finite(proposal.height) : finite(referenceHeight)
        let caption = subviews.firstIndex { $0[PostEditorialRoleKey.self] == .caption }
        let photos = subviews.firstIndex { $0[PostEditorialRoleKey.self] == .photos }
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        var heights = subviews.map { finite($0.sizeThatFits(.init(width: width, height: nil)).height) ?? 0 }
        let chrome = subviews.indices.filter { $0 != caption && $0 != photos }.reduce(gaps) { $0 + heights[$1] }
        let availableBody = viewport.map { max(0, $0 - chrome) }
        if let photos, let availableBody {
            // At large text sizes keep room for a readable first line instead
            // of letting a fixed photograph push all text and actions away.
            let textReserve = caption == nil ? 0 : min(minimumCaptionHeight, availableBody * 0.35)
            heights[photos] = min(heights[photos], max(0, availableBody - textReserve))
        }
        if isCompact, let caption, let availableBody {
            let captionBudget = max(0, availableBody - (photos.map { heights[$0] } ?? 0))
            heights[caption] = min(captionBudget,
                finite(subviews[caption].sizeThatFits(.init(width: width, height: captionBudget)).height) ?? 0)
        }
        let contentHeight = heights.reduce(gaps, +)
        return Measurement(size: CGSize(width: width, height: max(contentHeight, viewport ?? 0)),
                           heights: heights, contentHeight: contentHeight)
    }

    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}

/// Quiet individual prints, never another horizontal scroll surface. The
/// caller limits the strip to three and uses the existing lightbox for the rest.
struct PostNotebookPhotoLayout: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = finite(proposal.width) ?? 320
        let count = max(1, subviews.count)
        let tileWidth = count == 1 ? min(248, width) : max(0, width - spacing * CGFloat(count - 1)) / CGFloat(count)
        let naturalHeight = count == 1 ? min(178, tileWidth * 0.75)
            : count == 2 ? min(176, tileWidth * 1.08) : min(156, tileWidth * 1.36)
        return CGSize(width: width, height: finite(proposal.height) ?? naturalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = subviews.count
        let gap = min(spacing, bounds.width / CGFloat(count))
        let tileWidth = count == 1 ? min(248, bounds.width)
            : max(0, bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(index) * (tileWidth + gap), y: bounds.minY),
                                 anchor: .topLeading, proposal: .init(width: tileWidth, height: bounds.height))
        }
    }

    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}
