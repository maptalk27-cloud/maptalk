import SwiftUI

// MARK: - Button styles

extension ExperienceDetailView {
struct NeonButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(color.opacity(configuration.isPressed ? 0.55 : 0.3))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(color, lineWidth: 1.5)
            }
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .modifier(Theme.neonGlow(color))
    }
}

struct NeonIconButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(color.opacity(configuration.isPressed ? 0.55 : 0.3))
            )
            .overlay {
                Circle()
                    .stroke(color, lineWidth: 1.5)
            }
            .foregroundStyle(.white)
            .modifier(Theme.neonGlow(color))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
}
