import SwiftUI

struct RealButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 44))
        }
        .tint(Theme.neonWarning)
        .modifier(Theme.neonGlow(Theme.neonWarning))
    }
}

