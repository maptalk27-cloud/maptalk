import SwiftUI

/// A small card action: route planning belongs to the chosen map app, not our pager.
struct PlaceDirectionsButton: View {
    let destination: MapDirectionsDestination
    var showsTitle = true
    var onPresentationChanged: (Bool) -> Void = { _ in }

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.friendStoryChildPresentationChanged) private var childPresentationChanged
    @State private var presentationID = UUID()
    @State private var selectedDestination: MapDirectionsDestination?
    @State private var isChoosingMaps = false
    @State private var isOpeningMaps = false
    @State private var failedProvider: MapDirectionsProvider?

    private var hasPresentation: Bool {
        isChoosingMaps || isOpeningMaps || failedProvider != nil
    }

    var body: some View {
        Button {
            // Capture the tapped place, even if a feed refresh arrives during the chooser.
            selectedDestination = destination
            isChoosingMaps = true
        } label: {
            ViewThatFits(in: .horizontal) {
                if showsTitle && !dynamicTypeSize.isAccessibilitySize {
                    Label("Directions", systemImage: "arrow.turn.up.right")
                        .fixedSize()
                }
                Image(systemName: "arrow.turn.up.right")
                    .frame(width: 44)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOpeningMaps)
        .accessibilityLabel("Directions to \(destination.name)")
        .accessibilityHint("Choose Apple Maps or Google Maps")
        .accessibilityIdentifier("place.directions")
        .confirmationDialog("Open directions", isPresented: $isChoosingMaps,
                            titleVisibility: .visible, presenting: selectedDestination) { selected in
            ForEach(MapDirectionsProvider.allCases) { provider in
                Button(provider.title) { openDirections(to: selected, using: provider) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { selected in
            Text(selected.name)
        }
        .alert("Couldn't open maps", isPresented: Binding(
            get: { failedProvider != nil },
            set: { if !$0 { failedProvider = nil } }
        )) {
            Button("OK", role: .cancel) { failedProvider = nil }
        } message: {
            Text("Please try again or choose a different map app.")
        }
        .onChangeCompat(of: hasPresentation) { presented in
            childPresentationChanged?(presentationID, presented)
            onPresentationChanged(presented)
        }
        .onDisappear {
            childPresentationChanged?(presentationID, false)
            onPresentationChanged(false)
        }
    }

    private func openDirections(to selected: MapDirectionsDestination, using provider: MapDirectionsProvider) {
        isOpeningMaps = true
        openURL(selected.url(for: provider)) { accepted in
            // Acceptance only means the system handed off the URL, not that a route exists.
            if !accepted { failedProvider = provider }
            isOpeningMaps = false
        }
    }
}
