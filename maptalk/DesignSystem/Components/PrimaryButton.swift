import SwiftUI

struct PrimaryButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    init(action: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            content()
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
                .background(.black.opacity(0.8), in: .capsule)
                .overlay { Capsule().stroke(Theme.neonPrimary, lineWidth: 2) }
        }
        .tint(Theme.neonPrimary)
        .modifier(Theme.neonGlow(Theme.neonPrimary))
    }
}

