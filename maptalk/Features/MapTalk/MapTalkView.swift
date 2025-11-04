import Combine
import MapKit
import SwiftUI

struct MapTalkView: View {
    @StateObject var viewModel: MapTalkViewModel
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition, interactionModes: .all) {
                MapOverlays(
                    ratedPOIs: viewModel.ratedPOIs,
                    reals: viewModel.reals,
                    userCoordinate: viewModel.userCoordinate
                )
            }
            .ignoresSafeArea()

            SegmentedControl(
                options: ["World", "Friends"],
                selection: Binding(
                    get: { viewModel.mode.rawValue },
                    set: { viewModel.mode = .init(index: $0) }
                )
            )
            .padding(.top, 16)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    MapTalkControls(
                        onTapLocate: { viewModel.centerOnUser() },
                        onTapRating: {},
                        onTapReal: {}
                    )
                }
                .padding(.trailing, 20)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            cameraPosition = .region(viewModel.region)
            viewModel.onAppear()
        }
        .onReceive(viewModel.$region.dropFirst()) { newRegion in
            cameraPosition = .region(newRegion)
        }
    }
}

private struct MapTalkControls: View {
    let onTapLocate: () -> Void
    let onTapRating: () -> Void
    let onTapReal: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            LocateButton(action: onTapLocate)
            RatingButton(action: onTapRating)
            RealButton(action: onTapReal)
        }
    }
}
