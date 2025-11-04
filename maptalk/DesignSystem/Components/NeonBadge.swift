import SwiftUI

struct NeonBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6), in: .capsule)
            .overlay { Capsule().stroke(Theme.neonPrimary, lineWidth: 1) }
    }
}

