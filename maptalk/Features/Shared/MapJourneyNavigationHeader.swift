import SwiftUI

/// Shared Journey navigation chrome for every map surface.
/// It preserves the MapTalk hierarchy: exiting a Journey moves one folder up;
/// selecting a breadcrumb returns to that exact folder scope.
struct MapJourneyNavigationHeader: View {
    let path: [JourneyPost]
    let selectedJourneyId: UUID?
    let onSelect: (JourneyPost) -> Void
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onExit) {
                Image(systemName: "chevron.left")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(path, id: \.id) { journey in
                            JourneyBreadcrumbCard(
                                title: title(for: journey),
                                subtitle: "Journey",
                                leadingSymbol: String(title(for: journey).prefix(1)).uppercased(),
                                isSelected: journey.id == selectedJourneyId
                            )
                            .id(journey.id)
                            .onTapGesture {
                                onSelect(journey)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: selectedJourneyId)
                }
                .onAppear {
                    scrollToSelected(using: proxy, animated: false)
                }
                .onChangeCompat(of: selectedJourneyId) { _ in
                    scrollToSelected(using: proxy, animated: true)
                }
            }
        }
    }

    private func title(for journey: JourneyPost) -> String {
        let trimmed = journey.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? journey.displayLabel : trimmed
    }

    private func scrollToSelected(using proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedJourneyId else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    proxy.scrollTo(selectedJourneyId, anchor: .center)
                }
            } else {
                proxy.scrollTo(selectedJourneyId, anchor: .center)
            }
        }
    }
}

private struct JourneyBreadcrumbCard: View {
    let title: String
    let subtitle: String
    let leadingSymbol: String
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(backgroundFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(borderStyle, lineWidth: isSelected ? 1.5 : 1)
                }

            content
        }
        .frame(width: isSelected ? 260 : 60, height: 56)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isSelected)
    }

    @ViewBuilder
    private var content: some View {
        if isSelected {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            Text(leadingSymbol)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var backgroundFill: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Theme.neonPrimary.opacity(0.28), Color.black.opacity(0.82)],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
            )
        }
        return AnyShapeStyle(Color.black.opacity(0.35))
    }

    private var borderStyle: AnyShapeStyle {
        AnyShapeStyle(Color.white.opacity(isSelected ? 0.3 : 0.22))
    }
}
