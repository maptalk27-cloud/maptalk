import SwiftUI

struct RealButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ReelBadgeIcon()
                .modifier(Theme.neonGlow(Theme.neonAccent))
        }
        .buttonStyle(ReelBadgeButtonStyle())
    }
}

private struct ReelBadgeIcon: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Theme.neonPrimary,
                            Theme.neonAccent,
                            Theme.neonWarning,
                            Theme.neonPrimary
                        ]),
                        center: .center
                    ),
                    lineWidth: 2.4
                )
                .shadow(color: Theme.neonAccent.opacity(0.35), radius: 5)

            Circle()
                .fill(Color.black.opacity(0.75))
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                }
                .padding(2)

            VStack(spacing: 2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                Capsule()
                    .fill(Theme.neonAccent)
                    .frame(width: 14, height: 2)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .shadow(color: Theme.neonAccent.opacity(0.6), radius: 6)
        }
        .frame(width: 44, height: 44)
    }
}

private struct ReelBadgeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: configuration.isPressed)
    }
}
