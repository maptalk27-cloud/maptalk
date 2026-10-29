import Combine
import SwiftUI

/// The presentation lifecycle shared by every map content capsule.
///
/// A map surface owns *which* private or public item is selected. This object
/// owns the part that must never drift between surfaces: a new selection is
/// always shown as a compact sheet, and changing selection from the expanded
/// sheet gets a clean native-sheet reset instead of inheriting the large detent.
final class MapExperiencePresentation: ObservableObject {
    @Published private(set) var compactDetent: PresentationDetent

    @Published var isPresented = false
    @Published var detent: PresentationDetent
    @Published private(set) var contentRevision = 0
    @Published private(set) var isResettingPresentation = false

    private var resetToken = UUID()
    private var shouldReopenAfterDismiss = false

    init(compactDetent: PresentationDetent) {
        self.compactDetent = compactDetent
        self.detent = compactDetent
    }

    var isExpanded: Bool {
        detent == .large
    }

    /// A scoped navigation header needs room in addition to the unchanged
    /// card. Changing that allowance must not collapse an expanded story.
    func configureCompactDetent(_ compactDetent: PresentationDetent) {
        guard self.compactDetent != compactDetent else { return }
        let wasCompact = !isExpanded
        self.compactDetent = compactDetent
        if wasCompact { detent = compactDetent }
    }

    /// Use when a pin, list entry, or pager changes the selected content.
    func presentNewContent() {
        resetToCompact(presentIfNeeded: true)
    }

    /// Use when a host needs to return an already visible capsule to its
    /// compact state without creating a new selection.
    func collapseToCompact() {
        resetToCompact(presentIfNeeded: false)
    }

    func dismiss(preservingDetent: Bool = false) {
        resetToken = UUID()
        shouldReopenAfterDismiss = false
        isResettingPresentation = false
        if !preservingDetent { detent = compactDetent }
        isPresented = false
    }

    /// Opens the selected memory from its compact map capsule. The same
    /// action is shared by MapTalk and both private-map surfaces.
    func expand() {
        guard isPresented else { return }
        detent = .large
    }

    /// Call from the sheet's `onDismiss`. During an internal compact reset the
    /// sheet is momentarily dismissed on purpose, so host selection must stay.
    ///
    /// Returns `true` when the dismissal belongs to that internal reset. Hosts
    /// should then keep their selected map item intact.
    @discardableResult
    func didDismiss() -> Bool {
        if isResettingPresentation {
            isResettingPresentation = false
            detent = compactDetent

            let shouldReopen = shouldReopenAfterDismiss
            shouldReopenAfterDismiss = false
            if shouldReopen {
                let token = resetToken
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.resetToken == token,
                          self.isResettingPresentation == false else {
                        return
                    }
                    self.isPresented = true
                }
            }
            return true
        }

        resetToken = UUID()
        detent = compactDetent
        return false
    }

    private func resetToCompact(presentIfNeeded: Bool) {
        // A Journey route can request a compact reset and replace the capsule
        // content in the same run loop. Keep that native close/reopen alive so
        // the new content never inherits the previous expanded sheet.
        if isResettingPresentation {
            contentRevision &+= 1
            detent = compactDetent
            shouldReopenAfterDismiss = true
            return
        }

        let token = UUID()
        let needsNativeSheetReset = isPresented && isExpanded

        resetToken = token
        contentRevision &+= 1
        detent = compactDetent

        DispatchQueue.main.async { [weak self] in
            guard let self, self.resetToken == token else { return }
            self.detent = self.compactDetent
        }

        guard needsNativeSheetReset else {
            if presentIfNeeded {
                isPresented = true
            }
            return
        }

        isResettingPresentation = true
        shouldReopenAfterDismiss = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.resetToken == token else { return }
            self.isPresented = false
        }
    }
}

/// The canonical content capsule used on both the public map and MyMap.
///
/// A compact capsule opens its full interaction with a tap while retaining
/// the pager and controls inside the preview.
struct MapExperienceCapsule: View {
    let pager: ExperienceDetailView.SequencePager
    @Binding private var selection: UUID
    let isExpanded: Bool
    let onCollapsedTap: (() -> Void)?
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?
    let onJourneyAvatarStackTap: ((JourneyPost) -> Void)?
    let onPOIContributorViewed: ([String]) -> Void
    let isPOIContributorUnseen: ([String]) -> Bool

    init(
        pager: ExperienceDetailView.SequencePager,
        selection: Binding<UUID>,
        isExpanded: Bool,
        onCollapsedTap: (() -> Void)? = nil,
        journeyProvider: @escaping (UUID) -> JourneyPost? = { PreviewData.journey(for: $0) },
        userProvider: @escaping (UUID) -> User? = { _ in nil },
        onJourneyAvatarStackTap: ((JourneyPost) -> Void)? = nil,
        onPOIContributorViewed: @escaping ([String]) -> Void = { _ in },
        isPOIContributorUnseen: @escaping ([String]) -> Bool = { _ in true }
    ) {
        self.pager = pager
        _selection = selection
        self.isExpanded = isExpanded
        self.onCollapsedTap = onCollapsedTap
        self.journeyProvider = journeyProvider
        self.userProvider = userProvider
        self.onJourneyAvatarStackTap = onJourneyAvatarStackTap
        self.onPOIContributorViewed = onPOIContributorViewed
        self.isPOIContributorUnseen = isPOIContributorUnseen
    }

    var body: some View {
        ExperienceDetailView(
            sequencePager: pager,
            selection: $selection,
            isExpanded: isExpanded,
            onCollapsedTap: onCollapsedTap,
            onJourneyAvatarStackTap: onJourneyAvatarStackTap,
            journeyProvider: journeyProvider,
            userProvider: userProvider,
            onPOIContributorViewed: onPOIContributorViewed,
            isPOIContributorUnseen: isPOIContributorUnseen
        )
    }
}

/// The folder state when a Journey has not collected any memories yet.
struct MapJourneyEmptyCapsule: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.title3.weight(.medium))
                .foregroundStyle(Theme.neonPrimary)
            Text("No memories yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

extension View {
    /// Keep the native detent modifier subscribed to its owner even when the
    /// sheet's type-erased child updates independently (for example a story).
    func mapExperienceSheetChrome(presentation: MapExperiencePresentation) -> some View {
        modifier(ObservedMapExperienceSheetChrome(presentation: presentation))
    }

    /// Keeps the public and private map capsule chrome in lockstep.
    func mapExperienceSheetChrome(
        compactDetent: PresentationDetent,
        expandedDetent: PresentationDetent = .large,
        selection: Binding<PresentationDetent>
    ) -> some View {
        presentationDetents([compactDetent, expandedDetent], selection: selection)
            .presentationContentInteraction(.resizes)
            .presentationBackground(.thinMaterial)
            .presentationCompactAdaptation(.none)
            .applyBackgroundInteractionIfAvailable()
    }
}

private struct ObservedMapExperienceSheetChrome: ViewModifier {
    @ObservedObject var presentation: MapExperiencePresentation

    func body(content: Content) -> some View {
        content.mapExperienceSheetChrome(
            compactDetent: presentation.compactDetent,
            selection: $presentation.detent
        )
    }
}
