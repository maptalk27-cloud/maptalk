import SwiftUI

/// Color comparison only: never changes Post layout, media sizing or identity.
enum PostCardPalette: String, CaseIterable {
    case white, black

    static let storageKey = "maptalk.post-card-palette"

    var colorScheme: ColorScheme { self == .black ? .dark : .light }
    var background: Color {
        self == .black ? Color(red: 24 / 255, green: 27 / 255, blue: 25 / 255) : .white
    }
    var backgroundTop: Color {
        self == .black ? Color(red: 31 / 255, green: 34 / 255, blue: 31 / 255) : .white
    }
    var primary: Color {
        self == .black ? Color(red: 241 / 255, green: 238 / 255, blue: 229 / 255) : .primary
    }
    var secondary: Color {
        self == .black ? Color(red: 165 / 255, green: 170 / 255, blue: 162 / 255) : .secondary
    }
    var accent: Color { Color(red: 226 / 255, green: 215 / 255, blue: 190 / 255) }
}

private struct PostCardPaletteKey: EnvironmentKey {
    static let defaultValue: PostCardPalette = .white
}

extension EnvironmentValues {
    var postCardPalette: PostCardPalette {
        get { self[PostCardPaletteKey.self] }
        set { self[PostCardPaletteKey.self] = newValue }
    }
}

/// Applied only to the separate Posts sheet (and its isolated comparison).
/// Keep the neutral layout path enabled for both palettes, not the old Reel UI.
struct PostCardPaletteScope: ViewModifier {
    var isEnabled = true
    var isShowingPost = true
    @AppStorage(PostCardPalette.storageKey) private var palette: PostCardPalette = .white
    @Environment(\.colorScheme) private var inheritedColorScheme

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .environment(\.postCardPalette, isShowingPost ? palette : .white)
                .environment(\.colorScheme, isShowingPost ? palette.colorScheme : inheritedColorScheme)
                // Local card colors must not change presentation/window traits
                // while the native zoom animates over the map.
                .presentationBackground(isShowingPost
                    ? AnyShapeStyle(palette.background) : AnyShapeStyle(.thinMaterial))
        } else {
            content
        }
    }
}

struct PostCardBackdrop: View {
    @Environment(\.postCardPalette) private var palette

    var body: some View {
        LinearGradient(colors: [palette.backgroundTop, palette.background],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Shared by map display options and the isolated layout comparison screen.
struct PostCardPaletteSwitch: View {
    @AppStorage(PostCardPalette.storageKey) private var palette: PostCardPalette = .white

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PostCardPalette.allCases, id: \.self) { choice in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { palette = choice }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(choice.background)
                            .overlay { Circle().strokeBorder(Color.gray.opacity(0.35), lineWidth: 0.5) }
                            .frame(width: 9, height: 9)
                        Text(choice == .white ? "白" : "黑")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(palette == choice ? choice.primary : Color.black.opacity(0.65))
                    .frame(width: 52, height: 44)
                    .background(palette == choice ? choice.background : .clear, in: Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice == .white ? "White Post cards" : "Black Post cards")
                .accessibilityAddTraits(palette == choice ? .isSelected : [])
                .accessibilityIdentifier("post.palette.\(choice.rawValue)")
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .environment(\.colorScheme, .light)
    }
}
