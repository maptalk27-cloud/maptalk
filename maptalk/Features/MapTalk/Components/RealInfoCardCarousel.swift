import SwiftUI

struct RealInfoCardCarousel: View {
    let reals: [RealPost]
    let selectedId: UUID?
    let onSelect: (RealPost) -> Void
    let userProvider: (UUID) -> User?

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = geometry.size.width * 0.78
            let horizontalInset = max((geometry.size.width - cardWidth) / 2, 0)
            TabView(selection: selectionBinding()) {
                ForEach(reals, id: \.id) { real in
                    RealInfoCard(
                        real: real,
                        user: userProvider(real.userId),
                        isActive: selectedId == real.id
                    )
                    .frame(width: cardWidth)
                    .padding(.vertical, 8)
                    .padding(.horizontal, horizontalInset)
                    .tag(real.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .frame(height: 200)
    }

    private func selectionBinding() -> Binding<UUID> {
        let fallback = reals.first?.id ?? UUID()
        return Binding(
            get: { selectedId ?? fallback },
            set: { newValue in
                guard let real = reals.first(where: { $0.id == newValue }) else { return }
                onSelect(real)
            }
        )
    }
}

private struct RealInfoCard: View {
    let real: RealPost
    let user: User?
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 4) {
                    Text(user?.handle ?? "Unknown user")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                    Text(real.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Label(real.visibility.displayName, systemImage: "sparkle")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.neonPrimary.opacity(0.18), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(summaryText)
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text("Expires \(real.expiresAt.formatted(.relative(presentation: .named))) · Radius \(Int(real.radiusMeters))m")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(borderGradient, lineWidth: isActive ? 2 : 1)
                .opacity(isActive ? 1 : 0.45)
        }
        .shadow(color: Theme.neonPrimary.opacity(0.35), radius: isActive ? 18 : 8, y: 6)
        .scaleEffect(isActive ? 1.0 : 0.95)
        .animation(.interactiveSpring(response: 0.4, dampingFraction: 0.85), value: isActive)
    }

    private var summaryText: String {
        if let emoji = real.mediaType.emojiPayload {
            return "\(emoji) happening nearby"
        }
        return "Tap to explore this real-time moment."
    }

    private var avatar: some View {
        Group {
            if let url = user?.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Color.gray
                    default:
                        ProgressView()
                    }
                }
            } else {
                Text(user?.handle.prefix(2).uppercased() ?? "??")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(Color.white.opacity(0.6), lineWidth: 1)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Theme.neonPrimary.opacity(isActive ? 0.25 : 0.15),
                        Color.black.opacity(0.7)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: [
                Theme.neonPrimary.opacity(0.85),
                Theme.neonAccent.opacity(0.65)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private extension RealPost.Visibility {
    var displayName: String {
        switch self {
        case .publicAll:
            return "Public"
        case .friendsOnly:
            return "Friends"
        case .anonymous:
            return "Anonymous"
        }
    }
}

private extension String {
    var emojiPayload: String? {
        guard let range = range(of: "emoji:") else { return nil }
        let suffix = self[range.upperBound...]
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
