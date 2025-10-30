import SwiftUI

struct NeonTripCard: View {
    var title: String = "MapTalk – Neon"

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 6)
        .padding(.top, 12)
        .padding(.horizontal)
    }
}

#Preview {
    NeonTripCard()
        .padding()
        .background(Color.black.opacity(0.88))
}
