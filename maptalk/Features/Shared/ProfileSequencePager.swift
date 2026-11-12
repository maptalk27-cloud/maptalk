import SwiftUI

/// Profile's mixed history keeps each compact card's original layout. Only
/// the native sheet edge follows the horizontal scroll position.
enum ProfileCardPagingLayout {
    nonisolated static let poiFraction: CGFloat = 0.35
    nonisolated static let postFraction: CGFloat = 0.48

    static func fraction(for mode: ExperienceDetailView.Mode) -> CGFloat {
        if case .real = mode { return postFraction }
        return poiFraction
    }

    static func fraction(at position: CGFloat, items: [ExperienceDetailView.SequencePager.Item]) -> CGFloat {
        guard !items.isEmpty, position.isFinite else { return poiFraction }
        let position = min(max(position, 0), CGFloat(items.count - 1))
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, items.count - 1)
        let progress = position - CGFloat(lower)
        let start = fraction(for: items[lower].mode)
        return start + (fraction(for: items[upper].mode) - start) * progress
    }
}

private struct ProfileCardSheetMotionKey: EnvironmentKey {
    static let defaultValue: ProfileCardSheetMotion? = nil
}

extension EnvironmentValues {
    var profileCardSheetMotion: ProfileCardSheetMotion? {
        get { self[ProfileCardSheetMotionKey.self] }
        set { self[ProfileCardSheetMotionKey.self] = newValue }
    }
}

struct ProfileSequencePager<Page: View>: View {
    let items: [ExperienceDetailView.SequencePager.Item]
    @Binding var selection: UUID
    let isExpanded: Bool
    let isActive: Bool
    let usesFixedCompactCanvas: Bool
    @ObservedObject var motion: ProfileCardSheetMotion
    let background: (ExperienceDetailView.SequencePager.Item) -> Color
    @ViewBuilder let page: (ExperienceDetailView.SequencePager.Item) -> Page
    @Environment(\.canControlCardMotion) private var canControlCardMotion
    @State private var scrollID: UUID?
    @State private var hasAlignedInitialSelection = false
    @State private var isDrivingSheetHeight = false
    private struct AlignmentKey: Equatable {
        let maximumHeight: CGFloat
        let isActive: Bool
    }
    private nonisolated struct CompactViewport: Equatable {
        let width: CGFloat
        let maximumHeight: CGFloat
        let bottomInset: CGFloat

        var isLandscape: Bool { width > maximumHeight }
        var size: CGSize {
            CGSize(width: width, height: maximumHeight * ProfileCardPagingLayout.postFraction + bottomInset)
        }
    }
    // Native expanded sheets change both their width and detent ceiling a
    // little. Neither change should recompose the compact photo canvas.
    @State private var compactViewportReference: CompactViewport?

    init(items: [ExperienceDetailView.SequencePager.Item], selection: Binding<UUID>,
         isExpanded: Bool, motion: ProfileCardSheetMotion,
         isActive: Bool = true,
         usesFixedCompactCanvas: Bool = false,
         background: @escaping (ExperienceDetailView.SequencePager.Item) -> Color,
         @ViewBuilder page: @escaping (ExperienceDetailView.SequencePager.Item) -> Page) {
        self.items = items
        _selection = selection
        self.isExpanded = isExpanded
        self.isActive = isActive
        self.usesFixedCompactCanvas = usesFixedCompactCanvas
        self.motion = motion
        self.background = background
        self.page = page
        _scrollID = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        let resolvedMaximumHeight = motion.maximumDetentHeight
        let resolvedBottomInset = motion.bottomSafeArea
        return GeometryReader { geometry in
            // The sheet resolver supplies its real available height. A fixed
            // stage prevents native sheet resizing from resizing the pager.
            let maximum = motion.maximumDetentHeight > 0 ? motion.maximumDetentHeight
                : max(1, (geometry.size.height - motion.bottomSafeArea) / motion.compactFraction)
            let compactViewport: CGSize = {
                let current = CompactViewport(width: geometry.size.width,
                    maximumHeight: maximum, bottomInset: motion.bottomSafeArea)
                guard isExpanded, let reference = compactViewportReference,
                      reference.isLandscape == current.isLandscape else { return current.size }
                return reference.size
            }()
            // Native vertical dragging must still reveal a growing card. This
            // allowance is disabled during horizontal paging so it cannot feed
            // an in-flight detent change back into the page's layout.
            let verticalAllowance = isExpanded || motion.isPaging || usesFixedCompactCanvas ? 0
                : max(0, geometry.size.height - (maximum * motion.compactFraction + motion.bottomSafeArea))
            let stageHeight = isExpanded ? geometry.size.height
                : maximum * ProfileCardPagingLayout.postFraction + motion.bottomSafeArea + verticalAllowance

            ScrollViewReader { scrollProxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .bottom, spacing: 0) {
                    ForEach(items) { item in
                        page(item)
                            // Compact and expanded are two views of one card.
                            // Supply its settled compact canvas even while the
                            // native sheet is resizing or mounting a new page.
                            .environment(\.postCompactViewportSize, motion.maximumDetentHeight > 0
                                ? compactViewport
                                : nil)
                            .frame(width: geometry.size.width,
                                   height: isExpanded ? geometry.size.height
                                    : maximum * ProfileCardPagingLayout.fraction(for: item.mode)
                                        + motion.bottomSafeArea + verticalAllowance)
                            .frame(height: stageHeight, alignment: .bottom)
                            .background(background(item))
                            .clipped()
                            .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollID, anchor: .leading)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onScrollGeometryChange(for: CGFloat.self) { scroll in
                guard scroll.containerSize.width > 0 else { return 0 }
                return (scroll.contentOffset.x + scroll.contentInsets.leading) / scroll.containerSize.width
            } action: { _, position in
                guard isActive, canControlCardMotion() else { return }
                if !hasAlignedInitialSelection {
                    let initialIndex = items.firstIndex { $0.id == selection } ?? 0
                    guard abs(position - CGFloat(initialIndex)) < 0.01 else { return }
                    hasAlignedInitialSelection = true
                }
                // Real gesture/deceleration progress, not a timer or the
                // selection binding (which changes before paging finishes).
                guard isDrivingSheetHeight, motion.isPaging else { return }
                motion.setCompactFraction(ProfileCardPagingLayout.fraction(at: position, items: items))
            }
            .onScrollPhaseChange { _, phase, context in
                guard isActive, canControlCardMotion() else { return }
                let shouldCommitPage = phase == .idle && isDrivingSheetHeight
                switch phase {
                case .tracking, .interacting:
                    // Initial scrollTo/alignment is .animating, not a user
                    // swipe. Only a real gesture takes over native height.
                    isDrivingSheetHeight = true
                    motion.isPaging = true
                case .idle:
                    if isDrivingSheetHeight { motion.isPaging = false }
                    isDrivingSheetHeight = false
                case .decelerating, .animating:
                    // Deceleration retains an existing gesture's ownership;
                    // a programmatic animation never acquires it.
                    break
                @unknown default:
                    break
                }
                guard context.geometry.containerSize.width > 0, !items.isEmpty else { return }
                let position = (context.geometry.contentOffset.x + context.geometry.contentInsets.leading)
                    / context.geometry.containerSize.width
                if !hasAlignedInitialSelection {
                    let initialIndex = items.firstIndex { $0.id == selection } ?? 0
                    guard abs(position - CGFloat(initialIndex)) < 0.01 else { return }
                    hasAlignedInitialSelection = true
                }
                // Revealing a retained parent or resizing its native sheet
                // can also end at idle. Only a user's swipe changes the Post.
                guard shouldCommitPage else { return }
                let index = min(max(Int(position.rounded()), 0), items.count - 1)
                // ScrollPosition may report its new ID a tick after the idle
                // phase. Commit both together so selection cannot re-lock the
                // initial alignment gate at an already settled offset.
                scrollID = items[index].id
                motion.setCompactFraction(ProfileCardPagingLayout.fraction(for: items[index].mode))
                if selection != items[index].id { selection = items[index].id }
            }
            .frame(height: stageHeight)
            .frame(height: geometry.size.height, alignment: usesFixedCompactCanvas ? .top : .bottom)
            .clipped()
            .task(id: AlignmentKey(maximumHeight: motion.maximumDetentHeight, isActive: isActive)) {
                // A native sheet supplies its final width after the lazy
                // stack's first layout. Align to the requested record then;
                // never interpret that first zero offset as a user selection.
                await Task.yield()
                guard !Task.isCancelled, isActive, !hasAlignedInitialSelection,
                      canControlCardMotion() else { return }
                scrollProxy.scrollTo(selection, anchor: .leading)
            }
            }
        }
        .onGeometryChange(for: CompactViewport.self) { geometry in
            CompactViewport(width: geometry.size.width,
                maximumHeight: resolvedMaximumHeight, bottomInset: resolvedBottomInset)
        } action: { reference in
            guard !isExpanded, reference.width > 0, reference.maximumHeight > 0 else { return }
            if compactViewportReference != reference { compactViewportReference = reference }
        }
        .onChangeCompat(of: selection) { identifier in
            guard !motion.isPaging, scrollID != identifier else { return }
            hasAlignedInitialSelection = false
            scrollID = identifier
        }
        .onChangeCompat(of: isActive) { active in
            guard active else {
                if isDrivingSheetHeight, canControlCardMotion() { motion.isPaging = false }
                isDrivingSheetHeight = false
                return
            }
            hasAlignedInitialSelection = false
            scrollID = selection
        }
        .onChangeCompat(of: items.map(\.id)) { identifiers in
            guard isActive, canControlCardMotion(),
                  !identifiers.contains(selection), let first = identifiers.first else { return }
            if isDrivingSheetHeight { motion.isPaging = false }
            isDrivingSheetHeight = false
            hasAlignedInitialSelection = false
            scrollID = first
            selection = first
        }
        .onDisappear {
            if isActive, isDrivingSheetHeight, canControlCardMotion() { motion.isPaging = false }
            isDrivingSheetHeight = false
        }
    }
}
