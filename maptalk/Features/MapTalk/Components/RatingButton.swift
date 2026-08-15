import SwiftUI

/// The public-facing name is Place; POI remains an internal data model.
struct PlacePublishButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 44))
        }
        .tint(Theme.neonAccent)
        .modifier(Theme.neonGlow(Theme.neonAccent))
        .accessibilityLabel("Add a place")
        .accessibilityIdentifier("maptalk.add-place")
    }
}
