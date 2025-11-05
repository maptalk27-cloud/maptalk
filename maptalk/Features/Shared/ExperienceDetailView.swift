import MapKit
import SwiftUI

struct ExperienceDetailView: View {
    enum Mode {
        case real(RealPost, User?)
        case poi(RatedPOI)
    }

    struct ReelPager {
        struct Item: Identifiable {
            let real: RealPost
            let user: User?

            var id: UUID { real.id }
        }

        let items: [Item]
        let initialId: UUID
    }

    struct ReelContext {
        let pager: ReelPager
        var selection: Binding<UUID>
    }

    fileprivate struct ContentData {
        let title: String
        let subtitle: String?
        let badges: [String]
        let highlight: String?
        let secondary: String?
        let media: ExperienceMedia
        let accentColor: Color
        let backgroundGradient: [Color]
        let mapRegion: MKCoordinateRegion
        let primaryActionTitle: String
        let primaryActionSymbol: String
    }

    private let poi: RatedPOI?
    private let reelContext: ReelContext?
    private let isExpanded: Bool

    init(ratedPOI: RatedPOI, isExpanded: Bool) {
        self.poi = ratedPOI
        self.reelContext = nil
        self.isExpanded = isExpanded
    }

    init(reelPager: ReelPager, selection: Binding<UUID>, isExpanded: Bool) {
        self.poi = nil
        self.reelContext = ReelContext(pager: reelPager, selection: selection)
        self.isExpanded = isExpanded
    }

    var body: some View {
        let currentData = contentData(for: currentMode)

        ZStack {
            background(for: currentData)

            if isExpanded {
                expandedContent(using: currentData)
            } else {
                collapsedPreview(using: currentData)
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Presentation helpers

private extension ExperienceDetailView {
    var currentMode: Mode {
        if let context = reelContext {
            let identifier = context.selection.wrappedValue
            if let item = context.pager.items.first(where: { $0.id == identifier }) {
                return .real(item.real, item.user)
            }
            if let first = context.pager.items.first {
                return .real(first.real, first.user)
            }
        } else if let poi {
            return .poi(poi)
        }

        fatalError("ExperienceDetailView invoked without mode context.")
    }

    private func expandedContent(using data: ContentData) -> some View {
        Group {
            if let context = reelContext {
                TabView(selection: context.selection) {
                    ForEach(context.pager.items) { item in
                        ExperiencePanel(
                            data: contentData(for: .real(item.real, item.user))
                        )
                        .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))
            } else {
                ExperiencePanel(data: data)
            }
        }
    }

    private func collapsedPreview(using data: ContentData) -> some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 44, height: 4)

            if let context = reelContext {
                CompactReelPager(
                    pager: context.pager,
                    selection: context.selection
                )
                .frame(height: 110)
            } else {
                VStack(spacing: 8) {
                    Text(data.title)
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    if let subtitle = data.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }

                    if let highlight = data.highlight {
                        Text(highlight)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(data.accentColor.opacity(0.2), in: Capsule(style: .continuous))
                    }
                }
            }

            Text("向上拖动以查看更多实时内容")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private func background(for data: ContentData) -> some View {
        LinearGradient(
            colors: data.backgroundGradient,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay {
            RadialGradient(
                colors: [data.accentColor.opacity(0.45), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 420
            )
            .blur(radius: 40)
            .blendMode(.screen)
        }
        .overlay {
            Color.black.opacity(0.55).ignoresSafeArea()
        }
    }
}

// MARK: - Content data

private extension ExperienceDetailView {
    func contentData(for mode: Mode) -> ContentData {
        switch mode {
        case let .real(real, user):
            let accent = accentColor(for: real.visibility)
            let gradient = gradient(for: real.visibility)
            let badges = makeRealBadges(for: real)
            let highlight = real.mediaType.emojiPayload.map { "\($0) Live moment happening here." }
            let secondary = "Visibility • \(real.visibility.displayName)"
            let media = media(for: real)
            let mapRegion = MKCoordinateRegion(
                center: real.center,
                latitudinalMeters: max(real.radiusMeters * 8, 600),
                longitudinalMeters: max(real.radiusMeters * 8, 600)
            )
            return ContentData(
                title: user?.handle ?? "Shared Real",
                subtitle: "Posted \(real.createdAt.formatted(.relative(presentation: .named)))",
                badges: badges,
                highlight: highlight,
                secondary: secondary,
                media: media,
                accentColor: accent,
                backgroundGradient: gradient,
                mapRegion: mapRegion,
                primaryActionTitle: "React",
                primaryActionSymbol: "face.smiling"
            )
        case let .poi(rated):
            let accent = rated.poi.category.accentColor
            let averageScore = rated.ratings.compactMap(\.score).average
            let highlight = rated.ratings.first(where: { $0.text?.isEmpty == false })?.text
            let secondary: String?
            secondary = averageScore
                .map { avg in
                    let formatted = String(format: "%.1f", avg)
                    return "Average score \(formatted) · Latest vibes from friends."
                }
                ?? "Friends are starting to rate this spot."
            return ContentData(
                title: rated.poi.name,
                subtitle: rated.poi.category.displayName,
                badges: ["\(rated.ratings.count) Ratings"],
                highlight: highlight,
                secondary: secondary,
                media: media(for: rated),
                accentColor: accent,
                backgroundGradient: [Color.black, accent.opacity(0.25)],
                mapRegion: MKCoordinateRegion(
                    center: rated.poi.coordinate,
                    latitudinalMeters: 800,
                    longitudinalMeters: 800
                ),
                primaryActionTitle: "Add Rating",
                primaryActionSymbol: "star.fill"
            )
        }
    }

    func media(for real: RealPost) -> ExperienceMedia {
        if let emoji = real.mediaType.emojiPayload {
            return .emoji(emoji)
        }
        if let url = URL(string: real.mediaType), real.mediaType.isEmpty == false {
            return .image(url)
        }
        return .symbol("sparkles")
    }

    func media(for ratedPOI: RatedPOI) -> ExperienceMedia {
        if let emoji = ratedPOI.ratings.compactMap(\.emoji).first {
            return .emoji(emoji)
        }
        return .symbol(ratedPOI.poi.category.symbolName)
    }

    func makeRealBadges(for real: RealPost) -> [String] {
        let expiry = real.expiresAt.formatted(.relative(presentation: .named))
        return [real.visibility.displayName, "Expires \(expiry)"]
    }

    func accentColor(for visibility: RealPost.Visibility) -> Color {
        switch visibility {
        case .publicAll:
            return Theme.neonPrimary
        case .friendsOnly:
            return Theme.neonAccent
        case .anonymous:
            return Theme.neonWarning
        }
    }

    func gradient(for visibility: RealPost.Visibility) -> [Color] {
        switch visibility {
        case .publicAll:
            return [Color.black, Theme.neonPrimary.opacity(0.25)]
        case .friendsOnly:
            return [Color.black, Theme.neonAccent.opacity(0.28)]
        case .anonymous:
            return [Color.black, Theme.neonWarning.opacity(0.28)]
        }
    }
}

// MARK: - Experience panel

private struct ExperiencePanel: View {
    let data: ExperienceDetailView.ContentData

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                ExperienceMediaView(media: data.media, accentColor: data.accentColor)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [data.accentColor.opacity(0.8), .white.opacity(0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .blendMode(.screen)
                    }

                VStack(alignment: .leading, spacing: 18) {
                    badgesSection

                    if let highlight = data.highlight {
                        Text(highlight)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineSpacing(4)
                    }

                    if let secondary = data.secondary {
                        Text(secondary)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    coordinatePreview
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                }
                .modifier(Theme.neonGlow(data.accentColor))

                actionsBar
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 60)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text(data.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if let subtitle = data.subtitle {
                Text(subtitle)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 12)
    }

    private var badgesSection: some View {
        HStack(spacing: 10) {
            ForEach(data.badges, id: \.self) { badge in
                Text(badge)
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(data.accentColor.opacity(0.22))
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(data.accentColor.opacity(0.55), lineWidth: 1)
                    }
            }
            Spacer(minLength: 0)
        }
    }

    private var coordinatePreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Map Preview")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))

            Map(initialPosition: .region(data.mapRegion))
                .disabled(true)
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
        }
    }

    private var actionsBar: some View {
        HStack(spacing: 16) {
            Button {
                // hook up soon
            } label: {
                Label(data.primaryActionTitle, systemImage: data.primaryActionSymbol)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(NeonButtonStyle(color: data.accentColor))

            Button {
                // hook up soon
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.title3.bold())
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(NeonIconButtonStyle(color: data.accentColor))
        }
    }
}

// MARK: - Compact reel pager

private struct CompactReelPager: View {
    let pager: ExperienceDetailView.ReelPager
    let selection: Binding<UUID>

    var body: some View {
        TabView(selection: selection) {
            ForEach(pager.items) { item in
                CompactRealCard(real: item.real, user: item.user)
                    .padding(.horizontal, 8)
                    .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }
}

private struct CompactRealCard: View {
    let real: RealPost
    let user: User?

    var body: some View {
        HStack(spacing: 14) {
            avatar

            VStack(alignment: .leading, spacing: 6) {
                Text(user?.handle ?? "Unknown user")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(real.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Text(summaryText)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.neonPrimary.opacity(0.22), Color.black.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        }
    }

    private var summaryText: String {
        if let emoji = real.mediaType.emojiPayload {
            return "\(emoji) happening nearby"
        }
        return "Radius \(Int(real.radiusMeters))m · \(real.visibility.displayName)"
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
            Circle().stroke(Color.white.opacity(0.5), lineWidth: 1)
        }
    }
}

// MARK: - Media

private struct ExperienceMediaView: View {
    let media: ExperienceMedia
    let accentColor: Color

    var body: some View {
        ZStack {
            switch media {
            case let .emoji(emoji):
                VStack {
                    Text(emoji)
                        .font(.system(size: 92))
                        .shadow(color: accentColor.opacity(0.8), radius: 16)
                    Text("Live Drop")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RadialGradient(
                        colors: [accentColor.opacity(0.45), .black.opacity(0.8)],
                        center: .center,
                        startRadius: 10,
                        endRadius: 320
                    )
                )
            case let .image(url):
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                            .overlay {
                                LinearGradient(
                                    colors: [.black.opacity(0.05), .black.opacity(0.35)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                    case .empty:
                        ProgressView()
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            case let .symbol(systemName):
                placeholder(symbol: systemName)
            }
        }
    }

    private var placeholder: some View {
        placeholder(symbol: "sparkles")
    }

    private func placeholder(symbol: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(.white)
            Text("Content arriving soon")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [accentColor.opacity(0.35), .black.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private enum ExperienceMedia {
    case emoji(String)
    case image(URL)
    case symbol(String)
}

// MARK: - Button styles

private struct NeonButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(color.opacity(configuration.isPressed ? 0.55 : 0.3))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(color, lineWidth: 1.5)
            }
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .modifier(Theme.neonGlow(color))
    }
}

private struct NeonIconButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(color.opacity(configuration.isPressed ? 0.55 : 0.3))
            )
            .overlay {
                Circle()
                    .stroke(color, lineWidth: 1.5)
            }
            .foregroundStyle(.white)
            .modifier(Theme.neonGlow(color))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

// MARK: - Helpers

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

private extension Array where Element == Int {
    var average: Double? {
        guard isEmpty == false else { return nil }
        let total = reduce(0, +)
        return Double(total) / Double(count)
    }
}

private extension Array where Element == Rating {
    var average: Double? {
        compactMap(\.score).average
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

#if DEBUG
struct ExperienceDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let items = PreviewData.sampleReals.map {
            ExperienceDetailView.ReelPager.Item(real: $0, user: PreviewData.user(for: $0.userId))
        }
        let pager = ExperienceDetailView.ReelPager(
            items: items,
            initialId: items.first!.id
        )
        ExperienceDetailView(
            reelPager: pager,
            selection: .constant(items.first!.id),
            isExpanded: false
        )
        .preferredColorScheme(.dark)

        ExperienceDetailView(ratedPOI: PreviewData.sampleRatedPOIs[0], isExpanded: true)
            .preferredColorScheme(.dark)
    }
}
#endif
