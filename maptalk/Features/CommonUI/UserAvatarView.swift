import SwiftUI

struct UserAvatarView: View {
    let user: User
    var size: CGFloat = 84

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.45))
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                }
            if let url = user.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    default:
                        placeholder
                    }
                }
                .clipShape(Circle())
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(Theme.neonPrimary, lineWidth: 2.5)
                .shadow(color: Theme.neonPrimary.opacity(0.8), radius: 10)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        Text(String(user.handle.prefix(2)).uppercased())
            .font(.headline.bold())
            .foregroundStyle(.white)
    }
}
