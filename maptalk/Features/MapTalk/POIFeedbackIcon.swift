import SwiftUI

enum POIFeedbackIconSet: String, CaseIterable, Identifiable {
    case poi, emoji, emojiWarm, faces, marks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .poi: "POI"
        case .emoji: "Emoji 1"
        case .emojiWarm: "Emoji 2"
        case .faces: "Faces"
        case .marks: "Symbols"
        }
    }
}

/// A personal expression, never a place rating or an animated reaction.
struct POICustomFeelingIcon: View {
    let emoji: String
    let size: CGFloat

    var body: some View {
        Text(emoji)
            .font(.system(size: size))
            .fixedSize()
            .frame(width: size, height: size)
            .accessibilityLabel("Feeling: \(emoji)")
    }
}

/// Only the artwork: the enclosing picker owns selection and accessibility.
struct POIFeedbackIcon: View {
    let endorsement: RatedPOI.Endorsement
    let set: POIFeedbackIconSet
    let size: CGFloat

    private let ink = Color(white: 0.16)

    var body: some View {
        Group {
            switch set {
            case .poi:
                if endorsement == .hype {
                    ExperienceDetailView.EndorsementBadgeIcon(endorsement: endorsement, size: size * 0.8)
                } else {
                    // The chooser needs the symbol itself, not the black
                    // backing used by tiny badges over photos elsewhere.
                    Image(systemName: ExperienceDetailView.endorsementIconName(for: endorsement))
                        .font(.system(size: size * 0.82, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(ExperienceDetailView.endorsementColor(for: endorsement))
                }
            case .emoji:
                Text(emoji)
                    .font(.system(size: size))
                    .fixedSize()
            case .emojiWarm:
                Text(warmEmoji)
                    .font(.system(size: size))
                    .fixedSize()
            case .faces:
                face
            case .marks:
                Image(systemName: symbol)
                    .font(.system(size: size * symbolScale, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(ink)
            }
        }
        .frame(width: size, height: size)
    }

    private var emoji: String {
        switch endorsement {
        case .hype: "😍"
        case .solid: "🙂"
        case .meh: "😐"
        case .questionable: "🙁"
        }
    }

    private var warmEmoji: String {
        switch endorsement {
        case .hype: "🤩"
        case .solid: "😊"
        case .meh: "😐"
        case .questionable: "😕"
        }
    }

    private var symbol: String {
        switch endorsement {
        case .hype: "heart.fill"
        case .solid: "hand.thumbsup"
        case .meh: "minus"
        case .questionable: "hand.thumbsdown"
        }
    }

    private var symbolScale: CGFloat {
        switch endorsement {
        case .hype: 0.86
        case .solid, .questionable: 0.88
        case .meh: 0.76
        }
    }

    private var face: some View {
        ZStack {
            Circle()
                .strokeBorder(ink, lineWidth: size * 0.052)
                .padding(size * 0.035)

            if endorsement == .hype {
                eyeHeart(at: 0.32)
                eyeHeart(at: 0.68)
            } else {
                eyeDot(at: 0.34)
                eyeDot(at: 0.66)
            }

            POIFeedbackMouth(endorsement: endorsement)
                .stroke(ink, style: StrokeStyle(
                    lineWidth: size * 0.052,
                    lineCap: .round,
                    lineJoin: .round
                ))
        }
        .frame(width: size, height: size)
    }

    private func eyeHeart(at x: CGFloat) -> some View {
        Image(systemName: "heart.fill")
            .font(.system(size: size * 0.24, weight: .semibold))
            .foregroundStyle(ink)
            .position(x: size * x, y: size * 0.37)
    }

    private func eyeDot(at x: CGFloat) -> some View {
        Circle()
            .fill(ink)
            .frame(width: size * 0.078, height: size * 0.095)
            .position(x: size * x, y: size * 0.38)
    }
}

private struct POIFeedbackMouth: Shape {
    let endorsement: RatedPOI.Endorsement

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        return Path { path in
            switch endorsement {
            case .hype:
                path.move(to: point(0.29, 0.60))
                path.addQuadCurve(to: point(0.71, 0.60), control: point(0.50, 0.93))
            case .solid:
                path.move(to: point(0.31, 0.62))
                path.addQuadCurve(to: point(0.69, 0.62), control: point(0.50, 0.83))
            case .meh:
                path.move(to: point(0.33, 0.67))
                path.addLine(to: point(0.67, 0.67))
            case .questionable:
                path.move(to: point(0.32, 0.73))
                path.addQuadCurve(to: point(0.68, 0.73), control: point(0.50, 0.51))
            }
        }
    }
}
