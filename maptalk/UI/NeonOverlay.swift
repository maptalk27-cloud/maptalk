import SwiftUI

struct NeonOverlay: View {
    var body: some View {
        VStack { Spacer() }
            .background(
                ZStack {
                    LinearGradient(
                        colors: [
                            Color.purple.opacity(0.22),
                            Color.cyan.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .blendMode(.overlay)
                    Color.black.opacity(0.08).blendMode(.multiply)
                    RadialGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.18)
                        ],
                        center: .center,
                        startRadius: 40,
                        endRadius: 600
                    )
                }
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

#Preview {
    NeonOverlay()
        .background(Color.black)
}
