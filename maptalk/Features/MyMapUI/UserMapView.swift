import SwiftUI

struct UserMapView: View {
    @StateObject var viewModel: UserMapViewModel

    var body: some View {
        NavigationStack {
            UserMapHomeView(
                user: viewModel.identity.user,
                region: viewModel.mapRegion,
                records: UserMapRecord.make(
                    reels: viewModel.reels,
                    footprints: viewModel.footprints,
                    user: viewModel.identity.user
                ),
                userProvider: userProvider
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
}
