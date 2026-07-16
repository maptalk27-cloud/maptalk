import SwiftUI

enum Theme {
    static let neonPrimary = Color.cyan
    static let neonAccent = Color.mint
    static let neonWarning = Color.pink
    static let unreadRingColor = Color.cyan
    static let seenRingColor = Color.gray.opacity(0.55)

    static var unreadRingGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [
                neonPrimary,
                neonAccent,
                neonPrimary
            ]),
            center: .center
        )
    }

    static func neonGlow(_ color: Color) -> some ViewModifier {
        Glow(color: color)
    }

    private struct Glow: ViewModifier {
        let color: Color

        func body(content: Content) -> some View {
            content
                .shadow(color: color.opacity(0.6), radius: 8)
                .shadow(color: color.opacity(0.4), radius: 16)
        }
    }
}

struct StoryStatusCircleRing: View {
    let diameter: CGFloat
    let isUnseen: Bool
    var unreadLineWidth: CGFloat = 2.6
    var seenLineWidth: CGFloat = 1.5
    var unreadShadowRadius: CGFloat = 0

    var body: some View {
        Group {
            if isUnseen {
                Circle()
                    .strokeBorder(Theme.unreadRingGradient, lineWidth: unreadLineWidth)
                    .shadow(
                        color: Theme.unreadRingColor.opacity(unreadShadowRadius > 0 ? 0.34 : 0),
                        radius: unreadShadowRadius
                    )
            } else {
                Circle()
                    .strokeBorder(Theme.seenRingColor, lineWidth: seenLineWidth)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

struct StoryStatusDiamondRing: View {
    let size: CGFloat
    let isUnseen: Bool
    var cornerRadius: CGFloat = 7
    var unreadLineWidth: CGFloat = 2.4
    var seenLineWidth: CGFloat = 2.2
    var unreadShadowRadius: CGFloat = 0

    var body: some View {
        Group {
            if isUnseen {
                RoundedDiamond(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.unreadRingGradient, lineWidth: unreadLineWidth)
                    .shadow(
                        color: Theme.unreadRingColor.opacity(unreadShadowRadius > 0 ? 0.3 : 0),
                        radius: unreadShadowRadius
                    )
            } else {
                RoundedDiamond(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.seenRingColor, lineWidth: seenLineWidth)
            }
        }
        .frame(width: size, height: size)
    }
}

struct RoundedDiamond: InsettableShape {
    var cornerRadius: CGFloat = 6
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let top = CGPoint(x: rect.midX, y: rect.minY)
        let right = CGPoint(x: rect.maxX, y: rect.midY)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY)
        let left = CGPoint(x: rect.minX, y: rect.midY)
        let segmentLength = max(hypot(rect.width / 2, rect.height / 2), 1)
        let radius = min(cornerRadius, min(rect.width, rect.height) * 0.18)
        let t = min(radius / segmentLength, 0.42)

        func point(from vertex: CGPoint, toward target: CGPoint) -> CGPoint {
            CGPoint(
                x: vertex.x + (target.x - vertex.x) * t,
                y: vertex.y + (target.y - vertex.y) * t
            )
        }

        var path = Path()
        path.move(to: point(from: top, toward: right))
        path.addLine(to: point(from: right, toward: top))
        path.addQuadCurve(to: point(from: right, toward: bottom), control: right)
        path.addLine(to: point(from: bottom, toward: right))
        path.addQuadCurve(to: point(from: bottom, toward: left), control: bottom)
        path.addLine(to: point(from: left, toward: bottom))
        path.addQuadCurve(to: point(from: left, toward: top), control: left)
        path.addLine(to: point(from: top, toward: left))
        path.addQuadCurve(to: point(from: top, toward: right), control: top)
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> RoundedDiamond {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}
