import SwiftUI

struct TripInfoBox: View {
    var title: String = "Trip Summary"
    var etaText: String?
    var distanceText: String?
    var isComputing: Bool

    private let glassGradient = LinearGradient(
        colors: [
            Color(red: 0.28, green: 0.0, blue: 0.48).opacity(0.88),
            Color(red: 0.02, green: 0.35, blue: 0.68).opacity(0.92),
            Color(red: 0.05, green: 0.62, blue: 0.54).opacity(0.85)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private let borderGradient = LinearGradient(
        colors: [
            Color.purple.opacity(0.9),
            Color.cyan.opacity(0.9),
            Color.mint.opacity(0.85)
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    private var etaDisplay: String { etaText ?? "--" }
    private var distanceDisplay: String { distanceText ?? "--" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .tracking(3)
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                Spacer()
                if isComputing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white.opacity(0.85))
                }
            }

            HStack(spacing: 28) {
                metricBlock(icon: "timer", label: "ETA", value: etaDisplay)
                Divider()
                    .frame(height: 44)
                    .overlay(Color.white.opacity(0.18))
                metricBlock(icon: "map.fill", label: "DISTANCE", value: distanceDisplay)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(glassGradient)
                        .opacity(0.68)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(borderGradient, lineWidth: 1.4)
                        .blendMode(.plusLighter)
                )
        )
        .shadow(color: Color.cyan.opacity(0.28), radius: 28, y: 12)
    }

    private func metricBlock(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2)
            }
            .foregroundStyle(Color.white.opacity(0.65))

            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.95))
        }
    }
}

#Preview {
    VStack {
        Spacer()
        TripInfoBox(etaText: "12 min", distanceText: "3.5 mi", isComputing: true)
            .padding(.horizontal)
            .padding(.bottom, 24)
    }
    .frame(maxHeight: 400)
    .background(Color.black.opacity(0.92))
}
