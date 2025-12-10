import SwiftUI

struct ProfileHeroHeader: View {
    let identity: ProfileViewModel.Identity
    let summary: ProfileViewModel.Summary
    let persona: ProfileViewModel.Persona
    let onDismiss: DismissAction
    let topInset: CGFloat
    let heightHint: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [Theme.neonPrimary.opacity(0.95), Color.black.opacity(0.65)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .overlay(
                Color.black.opacity(0.25)
                    .blendMode(.overlay)
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                            )
                    }
                    Spacer()
                    Button {
                        // placeholder for share action
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                            )
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    ProfileAvatarView(user: identity.user, size: 72)
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(identity.displayName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                            Text(identity.subtitle)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        Text(persona.bio)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                        HStack(spacing: 12) {
                            ProfileStatChip(title: "POI", value: summary.footprintCount)
                            ProfileStatChip(title: "Reels", value: summary.reelCount)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, topInset + 6)
            .padding(.bottom, 18)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: heroHeight,
            maxHeight: heroHeight,
            alignment: .top
        )
        .ignoresSafeArea(edges: .top)
    }

    private var heroHeight: CGFloat {
        let minimumContent = topInset + 180
        return max(minimumContent, heightHint)
    }
}

struct ProfileWideButton: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.25), radius: 10, y: 6)
    }
}

private struct ProfileStatChip: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.12))
        )
    }
}
