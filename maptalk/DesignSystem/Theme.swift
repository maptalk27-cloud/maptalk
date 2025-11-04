import SwiftUI

enum Theme {
    static let neonPrimary = Color.cyan
    static let neonAccent = Color.mint
    static let neonWarning = Color.pink

    static func neonGlow(_ color: Color) -> some ViewModifier {
        Glow(color: color)
    }

    private struct Glow: ViewModifier {
        let color: Color

        func body(content: Content) -> some View {
            content
                .shadow(color: color.opacity(0.6), radius: 8)
                .shadow(color: color.opacity(0.4), radius: 16)
        }
    }
}

