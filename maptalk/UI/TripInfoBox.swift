import SwiftUI

struct TripInfoBox: View {
    var title: String = "Route Insights"
    var etaText: String?
    var distanceText: String?
    var isComputing: Bool

    private let accentGradient = LinearGradient(
        colors: [
            Color.pink.opacity(0.95),
            Color.purple.opacity(0.9),
            Color.cyan.opacity(0.88),
            Color.green.opacity(0.85),
            Color.orange.opacity(0.82)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private let highlightColor = Color.white.opacity(0.92)
    private let subtitleColor = Color.white.opacity(0.68)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption)
                .tracking(2)
                .foregroundStyle(subtitleColor)

            HStack(alignment: .center, spacing: 16) {
                infoColumn(systemName: "timer", label: "ETA", value: etaText ?? "--")
                Divider()
                    .frame(height: 32)
                    .overlay(subtitleColor.opacity(0.6))
                infoColumn(systemName: "map", label: "Distance", value: distanceText ?? "--")

                if isComputing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(highlightColor)
                        .scaleEffect(0.9)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    accentGradient
                        .opacity(0.38)
                        .blur(radius: 12)
                )
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(accentGradient, lineWidth: 1.3)
                        .opacity(0.9)
                )
        }
        .shadow(color: Color.purple.opacity(0.3), radius: 16, y: 10)
        .padding(.horizontal)
    }

    private func infoColumn(systemName: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.footnote.weight(.semibold))
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.5)
            }
            .foregroundStyle(subtitleColor)

            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(highlightColor)
        }
    }
}

#Preview {
    TripInfoBox(etaText: "12 min", distanceText: "3.5 mi", isComputing: true)
        .padding()
        .background(Color.black.opacity(0.92))
}
