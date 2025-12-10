import MapKit
import SwiftUI
import UIKit

struct ProfileHomeView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingMapDetail = false
    @State private var timelineDetailStartSegmentId: String?

    var body: some View {
        GeometryReader { proxy in
            let topInset = safeAreaTop()
            let heroHeightHint = proxy.size.height * 0.42
            let horizontalPadding: CGFloat = 8
            let safeWidth = proxy.size.width.isFinite ? proxy.size.width : 0
            let safeHeight = proxy.size.height.isFinite ? proxy.size.height : 0
            let availableWidth = max(0, safeWidth - (horizontalPadding * 2))
            let heightFactor: CGFloat = viewModel.identity.isCurrentUser ? 0.55 : 0.65
            let mapHeight = max(1, min(availableWidth, safeHeight * heightFactor))

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 20) {
                    ProfileHeroHeader(
                        identity: viewModel.identity,
                        summary: viewModel.summary,
                        persona: viewModel.persona,
                        onDismiss: dismiss,
                        topInset: topInset,
                        heightHint: heroHeightHint
                    )
                    .frame(maxWidth: .infinity)
                    .clipShape(
                        RoundedCorners(corners: [.bottomLeft, .bottomRight], radius: 32)
                    )
                    .shadow(color: Color.black.opacity(0.45), radius: 20, x: 0, y: 8)

                    Group {
                        if viewModel.identity.isCurrentUser {
                            Button {
                                isShowingMapDetail = true
                            } label: {
                                ProfileMapPreview(
                                    pins: viewModel.mapPins,
                                    footprints: viewModel.footprints,
                                    reels: viewModel.reels,
                                    region: viewModel.mapRegion,
                                    isActive: isShowingMapDetail == false
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: mapHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, horizontalPadding)
                        } else {
                            ProfileTimelinePreview(
                                pins: viewModel.mapPins,
                                footprints: viewModel.footprints,
                                reels: viewModel.reels,
                                region: viewModel.mapRegion,
                                userProvider: userProvider,
                                onOpenDetail: { segment in
                                    timelineDetailStartSegmentId = segment?.id
                                    isShowingMapDetail = true
                                }
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: mapHeight)
                            .padding(.horizontal, horizontalPadding)
                        }
                    }

                    ProfileWideButton(title: "Message")
                        .padding(.horizontal, horizontalPadding)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: [.top, .bottom])
        }
        .fullScreenCover(isPresented: $isShowingMapDetail) {
            ProfileMapDetailView(
                pins: viewModel.mapPins,
                reels: viewModel.reels,
                footprints: viewModel.footprints,
                profileUser: viewModel.identity.user,
                region: viewModel.mapRegion,
                userProvider: userProvider,
                onDismiss: {
                    isShowingMapDetail = false
                    timelineDetailStartSegmentId = nil
                },
                initialDisplayMode: .timeline,
                initialTimelineSegmentId: timelineDetailStartSegmentId
            )
        }
    }

    private var userProvider: (UUID) -> User? {
        { id in
            if id == viewModel.identity.user.id {
                return viewModel.identity.user
            }
            return PreviewData.user(for: id)
        }
    }

    private func safeAreaTop() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first?
            .safeAreaInsets.top ?? 0
    }

}

