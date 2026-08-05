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
                    footprints: viewModel.footprints
                ),
                journeyProvider: { id in
                    viewModel.journeyCatalog.first { $0.id == id }
                },
                journeyFolders: viewModel.journeyFolders,
                reels: viewModel.reels,
                footprints: viewModel.footprints,
                canEditJourneyFolders: viewModel.canEditJourneyFolders,
                onCreateJourneyFolder: { title, references in
                    viewModel.createJourneyFolder(
                        title: title,
                        memberReferences: references
                    )
                },
                onSaveJourneyFolder: { folder in
                    viewModel.saveJourneyFolder(folder)
                },
                onDeleteJourneyFolder: { id in
                    viewModel.deleteJourneyFolder(id: id)
                },
                onRemoveFromMyMap: { reference in
                    viewModel.removeFromMyMap(reference)
                },
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
