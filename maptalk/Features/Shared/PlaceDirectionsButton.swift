import SwiftUI

/// A small card action: open the landmark; navigation is a later choice in Maps.
struct PlaceDirectionsButton: View {
    let destination: MapDirectionsDestination
    @Environment(\.openURL) private var openURL
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
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOpeningMaps)
        .accessibilityLabel("Open \(destination.name) in Maps")
        .accessibilityHint("View this place in Apple Maps or Google Maps")
        .accessibilityIdentifier("place.directions")
        .popover(isPresented: $isChoosingMaps, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ForEach(MapDirectionsProvider.allCases) { provider in
                    Button {
                        guard let selectedDestination else { return }
                        isChoosingMaps = false
                        openPlace(selectedDestination, using: provider)
                    } label: {
                        Text(provider.title)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if provider != MapDirectionsProvider.allCases.last {
                        Divider().padding(.horizontal, 12)
                    }
                }
            }
            .padding(6)
            .frame(width: 184)
            .presentationCompactAdaptation(.popover)
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
        }
        .onDisappear {
            childPresentationChanged?(presentationID, false)
        }
    }

    private func openPlace(_ selected: MapDirectionsDestination, using provider: MapDirectionsProvider) {
        isOpeningMaps = true
        openURL(selected.url(for: provider)) { accepted in
            // Acceptance only means the system handed off the URL, not that Maps found a match.
            if !accepted { failedProvider = provider }
            isOpeningMaps = false
        }
    }
}
