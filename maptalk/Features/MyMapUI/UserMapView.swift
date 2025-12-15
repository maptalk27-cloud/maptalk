import SwiftUI

struct UserMapView: View {
    @StateObject var viewModel: UserMapViewModel
    @State private var selectedSegmentId: String?

    var body: some View {
        UserMapDetailView(
            pins: viewModel.mapPins,
            reels: viewModel.reels,
            footprints: viewModel.footprints,
            mapUser: viewModel.identity.user,
            region: viewModel.mapRegion,
            userProvider: userProvider,
            onDismiss: {},
            selectedSegmentId: $selectedSegmentId,
            onSelectSegment: { selectedSegmentId = $0 },
            onDismissWithSegment: { selectedSegmentId = $0 },
            initialDisplayMode: .timeline,
            showsCloseButton: false
        )
    }

    private var userProvider: (UUID) -> User? {
        { id in
            if id == viewModel.identity.user.id {
                return viewModel.identity.user
            }
            return PreviewData.user(for: id)
        }
    }
}
