import SwiftUI

struct NeonPin: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.cyan.opacity(0.22))
                .frame(width: 36, height: 36)
                .blur(radius: 6)
                .opacity(pulse ? 1 : 0.5)
                .scaleEffect(pulse ? 1.12 : 0.96)
                .animation(
                    .easeInOut(duration: 1).repeatForever(autoreverses: true),
                    value: pulse
                )
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .cyan.opacity(0.9), radius: 8)
                .shadow(color: .purple.opacity(0.6), radius: 16)
        }
        .onAppear { pulse = true }
    }
}

#Preview {
    NeonPin()
        .padding()
        .background(Color.black)
}
