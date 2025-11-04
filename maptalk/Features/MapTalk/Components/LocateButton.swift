import SwiftUI

struct LocateButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 44))
        }
        .tint(Theme.neonPrimary)
        .modifier(Theme.neonGlow(Theme.neonPrimary))
    }
}
