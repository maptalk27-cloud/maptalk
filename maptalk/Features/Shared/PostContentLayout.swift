import SwiftUI

nonisolated enum PostContentRole: Equatable {
    case header, caption, media, capsule, footer
}

private nonisolated struct PostContentRoleKey: LayoutValueKey {
    static let defaultValue: PostContentRole = .header
}

extension View {
    func postContentRole(_ role: PostContentRole) -> some View {
        layoutValue(key: PostContentRoleKey.self, value: role)
    }
}

struct PostContentColumnLayout: Layout {
    let isCompact: Bool
    var minimumHeight: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measurement = measure(proposal: proposal, subviews: subviews)
        let proposedHeight = isCompact ? finiteDimension(proposal.height) : nil
        return CGSize(width: measurement.width,
                      height: max(measurement.height, proposedHeight ?? minimumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measurement = measure(
            proposal: ProposedViewSize(width: bounds.width, height: isCompact ? bounds.height : nil),
            subviews: subviews
        )
        var y = bounds.minY
        let hasMedia = subviews.contains { $0[PostContentRoleKey.self] == .media }
        for index in subviews.indices {
            y += measurement.gaps[index]
            let height = measurement.heights[index]
            if subviews[index][PostContentRoleKey.self] == .caption, !hasMedia {
                // A short text-only post reads as a deliberate note. Center
                // it inside the actual reading area, without changing font or
                // moving the author/actions. Long text consumes this slack
                // naturally, so it returns to the normal top alignment.
                let trailingHeight = measurement.heights.dropFirst(index + 1).reduce(0, +)
                    + measurement.gaps.dropFirst(index + 1).reduce(0, +)
                let readingBottom = bounds.maxY - trailingHeight
                y += max(0, (readingBottom - y - height) / 2)
            } else if subviews[index][PostContentRoleKey.self] == .capsule {
                // Bubble and actions form one bottom-aligned group. Spare
                // room stays above them, not between the two touch targets.
                let remainingHeight = measurement.heights[index...].reduce(0, +)
                    + measurement.gaps.dropFirst(index + 1).reduce(0, +)
                y = max(y, bounds.maxY - remainingHeight)
            } else if subviews[index][PostContentRoleKey.self] == .footer {
                // Content keeps its minimum spacing; spare room belongs above the footer.
                y = max(y, bounds.maxY - height)
            }
            subviews[index].place(
                at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: measurement.width,
                    height: subviews[index][PostContentRoleKey.self] == .media ? nil : height
                )
            )
            y += height
        }
    }

    private struct Measurement {
        let width: CGFloat
        let heights: [CGFloat]
        let gaps: [CGFloat]
        var height: CGFloat { heights.reduce(0, +) + gaps.reduce(0, +) }
    }

    private func measure(proposal: ProposedViewSize, subviews: Subviews) -> Measurement {
        let width = finiteDimension(proposal.width) ?? 320
        var heights = Array(repeating: CGFloat.zero, count: subviews.count)
        let gaps = subviews.indices.map { index -> CGFloat in
            guard index > 0 else { return 0 }
            let role = subviews[index][PostContentRoleKey.self]
            let previousRole = subviews[index - 1][PostContentRoleKey.self]
            if role == .capsule || (previousRole == .capsule && role == .footer) { return 4 }
            if role == .footer { return 10 }
            if previousRole == .header, role == .caption { return 4 }
            return 8
        }
        // The sheet is a viewport onto the post, not a box everything must fit
        // inside. Media owns its natural height at the reading-column width;
        // the footer can fall below the compact viewport and appear on expand.
        let captions = subviews.indices.filter { subviews[$0][PostContentRoleKey.self] == .caption }
        for index in subviews.indices where subviews[index][PostContentRoleKey.self] != .caption {
            heights[index] = finiteDimension(
                subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            ) ?? 0
        }

        // Only text uses the spare vertical room. Media keeps its width-based
        // size, and the bottom controls keep their full touch targets.
        let captionBudget: CGFloat?
        if isCompact, let availableHeight = finiteDimension(proposal.height) {
            let fixedHeight = heights.reduce(0, +) + gaps.reduce(0, +)
            captionBudget = max(0, availableHeight - fixedHeight) / CGFloat(max(1, captions.count))
        } else {
            captionBudget = nil
        }
        for index in captions {
            heights[index] = finiteDimension(subviews[index].sizeThatFits(
                ProposedViewSize(width: width, height: captionBudget)
            ).height) ?? 0
        }

        return Measurement(width: width, heights: heights, gaps: gaps)
    }
}

/// Original typography and footer, with photos fitted into the compact reading
/// area. Expansion reuses that area rather than resizing the photograph cells.
struct PostRefinedColumnLayout: Layout {
    let isCompact: Bool
    let referenceHeight: CGFloat?
    let previewCaptionHeight: CGFloat
    var leadingInset: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measurement = measure(proposal: proposal, subviews: subviews)
        return CGSize(width: measurement.width, height: max(measurement.contentHeight, measurement.viewportHeight ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measurement = measure(proposal: .init(width: bounds.width, height: isCompact ? bounds.height : nil), subviews: subviews)
        let hasCaption = subviews.contains { $0[PostContentRoleKey.self] == .caption }
        let hasMedia = subviews.contains { $0[PostContentRoleKey.self] == .media }
        var y = bounds.minY
        for index in subviews.indices {
            y += measurement.gaps[index]
            let height = measurement.heights[index]
            let role = subviews[index][PostContentRoleKey.self]
            if (role == .media && !hasCaption) || (role == .caption && !hasMedia) {
                let trailingHeight = measurement.heights.dropFirst(index + 1).reduce(0, +)
                    + measurement.gaps.dropFirst(index + 1).reduce(0, +)
                let spareHeight = max(0, bounds.maxY - trailingHeight - y - height)
                // Photo-only posts remain connected to their author instead of
                // turning into a separate, vertically centered gallery page.
                y += role == .media ? min(20, spareHeight * 0.25) : spareHeight / 2
            } else if role == .capsule {
                let remainingHeight = measurement.heights[index...].reduce(0, +)
                    + measurement.gaps.dropFirst(index + 1).reduce(0, +)
                y = max(y, bounds.maxY - remainingHeight)
            } else if role == .footer {
                y = max(y, bounds.maxY - height)
            }
            let x = role == .media && !hasCaption ? bounds.minX : bounds.minX + measurement.inset
            subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                 proposal: .init(width: measurement.widths[index], height: height))
            y += height
        }
    }

    private struct Measurement {
        let width: CGFloat
        let inset: CGFloat
        let widths: [CGFloat]
        let viewportHeight: CGFloat?
        let heights: [CGFloat]
        let gaps: [CGFloat]
        var contentHeight: CGFloat { heights.reduce(0, +) + gaps.reduce(0, +) }
    }

    private func measure(proposal: ProposedViewSize, subviews: Subviews) -> Measurement {
        let width = finiteDimension(proposal.width) ?? 320
        let viewportHeight = isCompact ? finiteDimension(proposal.height) : finiteDimension(referenceHeight)
        // The native sheet may propose a few extra points while opening or
        // expanding. Media always uses the same compact budget; only text and
        // the footer follow the current viewport.
        let mediaViewportHeight = finiteDimension(referenceHeight) ?? viewportHeight
        let caption = subviews.firstIndex { $0[PostContentRoleKey.self] == .caption }
        let media = subviews.firstIndex { $0[PostContentRoleKey.self] == .media }
        // The layout owns the whole sheet width. Only the reading column is
        // indented; a photo-only composition gets an actually symmetric canvas.
        let inset = min(max(0, leadingInset), width / 2)
        let widths = subviews.map { subview in
            if subview[PostContentRoleKey.self] == .media {
                return caption == nil ? width : max(0, width - inset * 2)
            }
            return max(0, width - inset)
        }
        let gaps = subviews.indices.map { index -> CGFloat in
            guard index > 0 else { return 0 }
            let role = subviews[index][PostContentRoleKey.self]
            let previousRole = subviews[index - 1][PostContentRoleKey.self]
            if role == .capsule || (previousRole == .capsule && role == .footer) { return 4 }
            if role == .footer { return 10 }
            if previousRole == .header, role == .caption { return 4 }
            return 8
        }
        var heights = Array(repeating: CGFloat.zero, count: subviews.count)
        for index in subviews.indices where index != caption && index != media {
            heights[index] = finiteDimension(subviews[index].sizeThatFits(.init(width: widths[index], height: nil)).height) ?? 0
        }
        let chromeHeight = heights.reduce(0, +) + gaps.reduce(0, +)
        if let media {
            let textHeight = caption.map {
                min(previewCaptionHeight,
                    finiteDimension(subviews[$0].sizeThatFits(.init(width: widths[$0], height: previewCaptionHeight)).height) ?? 0)
            } ?? 0
            let mediaBudget = mediaViewportHeight.map { max(0, $0 - chromeHeight - textHeight) }
            heights[media] = finiteDimension(subviews[media].sizeThatFits(.init(width: widths[media], height: mediaBudget)).height) ?? 0
        }
        if let caption {
            let budget = isCompact ? viewportHeight.map { max(0, $0 - chromeHeight - (media.map { heights[$0] } ?? 0)) } : nil
            heights[caption] = finiteDimension(subviews[caption].sizeThatFits(.init(width: widths[caption], height: budget)).height) ?? 0
            if let budget { heights[caption] = min(heights[caption], budget) }
        }
        return Measurement(width: width, inset: inset, widths: widths, viewportHeight: viewportHeight, heights: heights, gaps: gaps)
    }
}

/// Size the actual aspect-fit image before centering it. A wider photo-only
/// canvas must not silently enlarge the original single-photo presentation.
struct PostRefinedSinglePhotoLayout: Layout {
    let centersPhoto: Bool
    let naturalWidthInset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = finiteDimension(proposal.width) ?? 320
        let image = imageSize(proposal: proposal, subviews: subviews)
        return CGSize(width: width, height: image.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let photo = subviews.first else { return }
        let size = imageSize(proposal: .init(bounds.size), subviews: subviews)
        let x = centersPhoto ? bounds.minX + max(0, (bounds.width - size.width) / 2) : bounds.minX
        photo.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: .init(size))
    }

    private func imageSize(proposal: ProposedViewSize, subviews: Subviews) -> CGSize {
        guard let photo = subviews.first else { return .zero }
        let canvasWidth = finiteDimension(proposal.width) ?? 320
        let maximumWidth = max(0, canvasWidth - max(0, naturalWidthInset))
        guard maximumWidth > 0 else { return .zero }
        let natural = photo.sizeThatFits(.init(width: maximumWidth, height: nil))
        guard natural.width.isFinite, natural.height.isFinite, natural.width > 0, natural.height > 0 else { return .zero }
        let widthScale = min(1, maximumWidth / natural.width)
        let heightScale = finiteDimension(proposal.height).map { $0 / natural.height } ?? 1
        let scale = min(widthScale, heightScale)
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }
}

/// A continuous aspect-ratio policy, not a separate card for every orientation.
/// Ordinary photos remain complete. Very tall sources show their beginning;
/// panoramas show the middle. The owner clips the viewport, never the source.
struct PostSinglePhotoViewportLayout: Layout {
    private let minimumRatio: CGFloat = 9.0 / 16.0
    private let maximumRatio: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measurement(proposal: proposal, subviews: subviews).viewport
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let image = subviews.first else { return }
        let measured = measurement(proposal: .init(bounds.size), subviews: subviews)
        guard measured.source.width > 0, measured.source.height > 0 else { return }
        let scale = max(bounds.width / measured.source.width, bounds.height / measured.source.height)
        let drawnSize = CGSize(width: measured.source.width * scale, height: measured.source.height * scale)
        let isLongImage = measured.source.width / measured.source.height < minimumRatio
        let x = bounds.minX + (bounds.width - drawnSize.width) / 2
        let y = isLongImage ? bounds.minY : bounds.minY + (bounds.height - drawnSize.height) / 2
        // Offer the image its own aspect ratio, even when part of it sits
        // outside the preview. It is never stretched to the window's ratio.
        image.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .init(drawnSize))
    }

    private func measurement(proposal: ProposedViewSize, subviews: Subviews) -> (source: CGSize, viewport: CGSize) {
        guard let image = subviews.first else { return (.zero, .zero) }
        let width = finiteDimension(proposal.width) ?? 320
        guard width > 0 else { return (.zero, .zero) }
        let natural = image.sizeThatFits(.init(width: width, height: nil))
        guard natural.width.isFinite, natural.height.isFinite, natural.width > 0, natural.height > 0 else {
            return (.zero, .zero)
        }
        let ratio = min(maximumRatio, max(minimumRatio, natural.width / natural.height))
        let height = min(width / ratio, finiteDimension(proposal.height) ?? width / ratio)
        return (natural, CGSize(width: height * ratio, height: height))
    }
}

/// Every cell is square, including the three-photo composition. The small
/// right squares have side s; the left square has side 2s + one gap.
struct PostRefinedPhotoLayout: Layout {
    var centersGroup = false
    var naturalWidthInset: CGFloat = 0
    private let spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        metrics(proposal: proposal, count: subviews.count).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = metrics(proposal: .init(bounds.size), count: subviews.count)
        let xOffset = centersGroup ? max(0, (bounds.width - layout.groupWidth) / 2) : 0
        for (index, frame) in layout.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + xOffset + frame.minX, y: bounds.minY + frame.minY),
                                 anchor: .topLeading, proposal: .init(frame.size))
        }
    }

    private struct Metrics {
        let size: CGSize
        let groupWidth: CGFloat
        let frames: [CGRect]
    }

    private func metrics(proposal: ProposedViewSize, count: Int) -> Metrics {
        let width = finiteDimension(proposal.width) ?? 320
        guard count > 0 else { return Metrics(size: CGSize(width: width, height: 0), groupWidth: 0, frames: []) }
        // The full canvas is for centering, not a reason to enlarge the images
        // when a caption is absent. Keep the captioned post's photo scale.
        let photoWidth = max(0, width - max(0, naturalWidthInset))
        let heightLimit = finiteDimension(proposal.height)
        let gap = min(spacing, photoWidth / 3, heightLimit.map { $0 / 3 } ?? spacing)
        if count == 3 {
            let widthSide = max(0, (photoWidth - gap * 2) / 3)
            let heightSide = heightLimit.map { max(0, ($0 - gap) / 2) } ?? widthSide
            let small = min(widthSide, heightSide)
            let large = small * 2 + gap
            let groupWidth = large + gap + small
            return Metrics(size: CGSize(width: width, height: large), groupWidth: groupWidth,
                           frames: [CGRect(x: 0, y: 0, width: large, height: large),
                                    CGRect(x: large + gap, y: 0, width: small, height: small),
                                    CGRect(x: large + gap, y: small + gap, width: small, height: small)])
        }
        let columns = min(count, count == 2 || count == 4 ? 2 : 3)
        let rows = (count + columns - 1) / columns
        let widthSide = max(0, (photoWidth - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let heightSide = heightLimit.map { max(0, ($0 - gap * CGFloat(rows - 1)) / CGFloat(rows)) } ?? widthSide
        let side = min(widthSide, heightSide)
        let groupWidth = side * CGFloat(columns) + gap * CGFloat(columns - 1)
        let height = side * CGFloat(rows) + gap * CGFloat(rows - 1)
        let frames = (0..<count).map {
            let row = $0 / columns
            let cellsInRow = min(columns, count - row * columns)
            let rowOffset = centersGroup ? CGFloat(columns - cellsInRow) * (side + gap) / 2 : 0
            return CGRect(x: rowOffset + CGFloat($0 % columns) * (side + gap), y: CGFloat(row) * (side + gap), width: side, height: side)
        }
        return Metrics(size: CGSize(width: width, height: height), groupWidth: groupWidth, frames: frames)
    }
}

struct PostPhotoGridLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        metrics(proposal: proposal, count: subviews.count).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = metrics(proposal: proposal, count: subviews.count)
        guard grid.columns > 0 else { return }
        for index in subviews.indices {
            let column = index % grid.columns
            let row = index / grid.columns
            subviews[index].place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * (grid.tile.width + grid.spacing),
                            y: bounds.minY + CGFloat(row) * (grid.tile.height + grid.spacing)),
                anchor: .topLeading,
                proposal: ProposedViewSize(grid.tile)
            )
        }
    }

    private struct Metrics {
        let columns: Int
        let tile: CGSize
        let spacing: CGFloat
        let size: CGSize
    }

    private func metrics(proposal: ProposedViewSize, count: Int) -> Metrics {
        guard count > 0 else { return Metrics(columns: 0, tile: .zero, spacing: 0, size: .zero) }
        let columns = min(count, count == 2 || count == 4 ? 2 : 3)
        let rows = (count + columns - 1) / columns
        let availableWidth = finiteDimension(proposal.width) ?? 320
        let gap = min(finiteDimension(spacing) ?? 4, availableWidth / 2)
        let horizontalGaps = gap * CGFloat(columns - 1)
        let verticalGaps = gap * CGFloat(rows - 1)
        // All counts use the full three-column reading width. Four photos use
        // two rows of the same squares; neither detent nor footer shrinks them.
        let side = max(0, availableWidth - gap * 2) / 3
        let tile = CGSize(width: side, height: side)
        return Metrics(columns: columns, tile: tile, spacing: gap,
                       size: CGSize(width: tile.width * CGFloat(columns) + horizontalGaps,
                                    height: tile.height * CGFloat(rows) + verticalGaps))
    }

}

private func finiteDimension(_ value: CGFloat?) -> CGFloat? {
    guard let value, value.isFinite else { return nil }
    return max(0, value)
}
