import SwiftUI

struct RealStoriesRow: View {
    let reals: [RealPost]
    let selectedId: UUID?
    let onSelect: (RealPost) -> Void
    let userProvider: (UUID) -> User?

    @GestureState private var dragOffset: CGFloat = 0

    private let itemWidth: CGFloat = 72
    private let spacing: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let items = carouselItems()
            let selectedIndex = currentSelectedIndex
            let springAnimation: Animation = .interactiveSpring(response: 0.32, dampingFraction: 0.82)
            let baseOffset = carouselOffset(containerWidth: availableWidth, selectedIndex: selectedIndex)

            HStack(spacing: spacing) {
                ForEach(items) { item in
                    reelButton(for: item, isSelected: item.index == selectedIndex, springAnimation: springAnimation)
                }
            }
            .frame(width: availableWidth, alignment: .leading)
            .offset(x: baseOffset + dragOffset)
            .animation(.interactiveSpring(response: 0.42, dampingFraction: 0.82), value: selectedId)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .updating($dragOffset) { value, state, _ in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        state = value.translation.width
                    }
                    .onEnded { value in
                        handleDragEnd(value.translation.width, currentIndex: selectedIndex)
                    }
            )
        }
        .frame(height: 108)
    }

    private func carouselItems() -> [CarouselItem] {
        reals.enumerated().map { index, real in
            CarouselItem(index: index, real: real, user: userProvider(real.userId))
        }
    }

    private func reelButton(for item: CarouselItem, isSelected: Bool, springAnimation: Animation) -> some View {
        return Button {
            select(index: item.index)
        } label: {
            VStack(spacing: 6) {
                RealStoryBadge(
                    user: item.user,
                    isSelected: isSelected
                )
                Text(item.user?.handle ?? "you")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: itemWidth)
            .scaleEffect(isSelected ? 1.08 : 1.0)
            .opacity(isSelected ? 1 : 0.82)
            .animation(springAnimation, value: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func carouselOffset(containerWidth: CGFloat, selectedIndex: Int) -> CGFloat {
        guard reals.isEmpty == false else { return 0 }
        let base = containerWidth / 2 - itemWidth / 2
        let step = itemWidth + spacing
        return base - CGFloat(selectedIndex) * step
    }

    private func handleDragEnd(_ translation: CGFloat, currentIndex: Int) {
        let threshold = itemWidth * 0.35
        var newIndex = currentIndex

        if translation <= -threshold {
            newIndex = min(currentIndex + 1, reals.count - 1)
        } else if translation >= threshold {
            newIndex = max(currentIndex - 1, 0)
        }

        select(index: newIndex)
    }

    private func select(index: Int) {
        guard reals.indices.contains(index) else { return }
        onSelect(reals[index])
    }

    private var currentSelectedIndex: Int {
        guard
            let selectedId,
            let index = reals.firstIndex(where: { $0.id == selectedId })
        else {
            return 0
        }
        return index
    }

    private struct CarouselItem: Identifiable {
        let index: Int
        let real: RealPost
        let user: User?

        var id: UUID { real.id }
    }
}

private struct RealStoryBadge: View {
    let user: User?
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Theme.neonPrimary,
                            Theme.neonAccent,
                            Theme.neonWarning,
                            Theme.neonPrimary
                        ]),
                        center: .center
                    ),
                    lineWidth: 3
                )
                .frame(width: 66, height: 66)
                .shadow(color: Theme.neonPrimary.opacity(0.6), radius: 12)

            Circle()
                .fill(.black.opacity(0.45))
                .frame(width: 62, height: 62)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                }

            if let url = user?.avatarURL {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 60, height: 60)
                .clipShape(Circle())
            } else {
                Text(initials)
                    .font(.headline.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 70, height: 70)
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Circle()
                    .fill(Theme.neonPrimary)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 4, y: 4)
            }
        }
    }

    private var initials: String {
        guard let handle = user?.handle else { return "ME" }
        return String(handle.prefix(2)).uppercased()
    }
}
