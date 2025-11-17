import SwiftUI

struct RealStoriesRow: View {
    struct POISharer: Identifiable {
        let id: UUID
        let ratedPOI: RatedPOI
        let user: User?
        let timestamp: Date

        var poiName: String { ratedPOI.poi.name }
        var category: POICategory { ratedPOI.poi.category }
    }

    let reals: [RealPost]
    let selectedId: UUID?
    let onSelect: (RealPost, Bool) -> Void
    let userProvider: (UUID) -> User?
    let alignTrigger: Int
    let poiSharers: [POISharer]
    let onSelectPOISharer: (POISharer) -> Void

    init(
        reals: [RealPost],
        selectedId: UUID?,
        onSelect: @escaping (RealPost, Bool) -> Void,
        userProvider: @escaping (UUID) -> User?,
        alignTrigger: Int,
        poiSharers: [POISharer] = [],
        onSelectPOISharer: @escaping (POISharer) -> Void = { _ in }
    ) {
        self.reals = reals
        self.selectedId = selectedId
        self.onSelect = onSelect
        self.userProvider = userProvider
        self.alignTrigger = alignTrigger
        self.poiSharers = poiSharers
        self.onSelectPOISharer = onSelectPOISharer
    }

    private let spacing: CGFloat = 16

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(reals, id: \.id) { real in
                        reelButton(for: real, isSelected: selectedId == real.id)
                            .id(real.id)
                    }
                    ForEach(poiSharers) { sharer in
                        poiButton(for: sharer)
                    }
                }
            }
            .onChange(of: alignTrigger) { _ in
                centerOnSelected(using: proxy, animated: true)
            }
        }
        .frame(height: 108)
    }

    private func reelButton(for real: RealPost, isSelected: Bool) -> some View {
        let user = userProvider(real.userId)
        return Button {
            onSelect(real, true)
        } label: {
            VStack(spacing: 6) {
                RealStoryBadge(
                    user: user,
                    isSelected: isSelected
                )
                Text(user?.handle ?? "you")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: 72)
            .scaleEffect(isSelected ? 1.08 : 1.0)
            .opacity(isSelected ? 1 : 0.82)
            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.82), value: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func poiButton(for sharer: POISharer) -> some View {
        Button {
            onSelectPOISharer(sharer)
        } label: {
            VStack(spacing: 6) {
                POISharerBadge(user: sharer.user, category: sharer.category)
                Text(sharer.poiName)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
    }

    private func centerOnSelected(using proxy: ScrollViewProxy, animated: Bool) {
        guard let id = selectedId else { return }
        let anchor = anchorPoint(for: id)
        let action = {
            proxy.scrollTo(id, anchor: anchor)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.28)) {
                action()
            }
        } else {
            action()
        }
    }

    private func anchorPoint(for id: UUID) -> UnitPoint {
        guard let index = reals.firstIndex(where: { $0.id == id }) else {
            return .center
        }
        if index == 0 {
            return .leading
        } else if index == reals.count - 1 {
            return .trailing
        }
        return .center
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

private struct POISharerBadge: View {
    let user: User?
    let category: POICategory

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    AngularGradient(
                        gradient: Gradient(colors: category.markerGradientColors + [category.markerGradientColors.first ?? .white]),
                        center: .center
                    ),
                    lineWidth: 3
                )
                .frame(width: 66, height: 66)
                .shadow(color: category.markerGradientColors.last?.opacity(0.6) ?? .black.opacity(0.6), radius: 10)

            Circle()
                .fill(Color.black.opacity(0.45))
                .frame(width: 62, height: 62)
                .overlay {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 1)
                }

            if let url = user?.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    default:
                        placeholder
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(Circle())
            } else {
                placeholder
            }
        }
        .frame(width: 70, height: 70)
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: 20, height: 20)
                .overlay {
                    Image(systemName: category.symbolName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .offset(x: 4, y: 4)
        }
    }

    private var placeholder: some View {
        Text(initials)
            .font(.headline.bold())
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .background(Color.gray.opacity(0.4))
            .clipShape(Circle())
    }

    private var initials: String {
        guard let handle = user?.handle else { return "PO" }
        return String(handle.prefix(2)).uppercased()
    }
}
