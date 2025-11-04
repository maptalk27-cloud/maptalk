import SwiftUI

struct RatingButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 44))
        }
        .tint(Theme.neonAccent)
        .modifier(Theme.neonGlow(Theme.neonAccent))
    }
}

