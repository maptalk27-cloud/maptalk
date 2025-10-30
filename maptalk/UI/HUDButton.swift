import SwiftUI

struct HUDButton: View {
    let systemName: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .padding(12)
        }
        .background(.ultraThinMaterial, in: Circle())
        .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.5)
    }
}
