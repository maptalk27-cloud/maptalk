import SwiftUI

struct NeonTripCard: View {
    let title: String
    let etaText: String?
    let distanceText: String?
    let isComputing: Bool

    init(title: String = "MapTalk – Neon",
         etaText: String?,
         distanceText: String?,
         isComputing: Bool) {
        self.title = title
        self.etaText = etaText
        self.distanceText = distanceText
        self.isComputing = isComputing
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
            if let etaText, let distanceText {
                Text("· \(etaText) • \(distanceText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isComputing {
                ProgressView().scaleEffect(0.8)
            }
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
    VStack {
        NeonTripCard(title: "MapTalk – Neon", etaText: "12 min", distanceText: "3.4 km", isComputing: false)
        NeonTripCard(title: "MapTalk – Neon", etaText: nil, distanceText: nil, isComputing: true)
    }
    .padding()
    .background(Color.black.opacity(0.88))
}
