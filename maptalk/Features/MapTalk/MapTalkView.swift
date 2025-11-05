import Combine
import MapKit
import SwiftUI

struct MapTalkView: View {
    @StateObject var viewModel: MapTalkViewModel
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedRealId: UUID?
    @State private var activeExperience: ActiveExperience?
    @State private var experienceDetent: PresentationDetent = .fraction(0.25)

    var body: some View {
        let sortedReals = viewModel.reals.sorted { $0.createdAt < $1.createdAt }
        let realItems = sortedReals.map { ActiveExperience.RealItem(real: $0, user: viewModel.user(for: $0.userId)) }
        let updateSelection: (RealPost, Bool) -> Void = { real, shouldPresent in
            selectedRealId = real.id
            viewModel.focus(on: real)
            if shouldPresent || activeExperience != nil {
                activeExperience = .real(items: realItems, currentId: real.id)
            }
            if shouldPresent {
                experienceDetent = .fraction(0.25)
            }
        }
        let presentReal: (RealPost) -> Void = { real in
            updateSelection(real, true)
        }

        ZStack(alignment: .top) {
            Map(position: $cameraPosition, interactionModes: .all) {
                MapOverlays(
                    ratedPOIs: viewModel.ratedPOIs,
                    reals: viewModel.reals,
                    userCoordinate: viewModel.userCoordinate,
                    onSelectPOI: { rated in
                        viewModel.focus(on: rated)
                        activeExperience = .poi(rated)
                        experienceDetent = .fraction(0.25)
                    },
                    onSelectReal: { real in
                        presentReal(real)
                    }
                )
            }
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                SegmentedControl(
                    options: ["World", "Friends"],
                    selection: Binding(
                        get: { viewModel.mode.rawValue },
                        set: { viewModel.mode = .init(index: $0) }
                    )
                )
                .frame(maxWidth: .infinity)

                if sortedReals.isEmpty == false {
                    RealStoriesRow(
                        reals: sortedReals,
                        selectedId: selectedRealId,
                        onSelect: presentReal,
                        userProvider: viewModel.user(for:)
                    )
                }
            }
            .padding(.horizontal, 16)
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
        .sheet(item: $activeExperience, onDismiss: {
            experienceDetent = .fraction(0.25)
        }) { experience in
            let isExpanded = experienceDetent == .large
            Group {
                switch experience {
                case let .real(context):
                    let pagerItems = context.items.map { item in
                        ExperienceDetailView.ReelPager.Item(real: item.real, user: item.user)
                    }
                    let pager = ExperienceDetailView.ReelPager(
                        items: pagerItems,
                        initialId: context.currentId
                    )
                    let selectionBinding = Binding<UUID>(
                        get: { selectedRealId ?? context.currentId },
                        set: { newValue in
                            if let real = context.items.first(where: { $0.id == newValue })?.real {
                                updateSelection(real, false)
                            }
                        }
                    )
                    ExperienceDetailView(reelPager: pager, selection: selectionBinding, isExpanded: isExpanded)
                case let .poi(rated):
                    ExperienceDetailView(ratedPOI: rated, isExpanded: isExpanded)
                }
            }
            .presentationDetents([.fraction(0.25), .large], selection: $experienceDetent)
            .presentationBackground(.thinMaterial)
        }
        .onAppear {
            cameraPosition = .region(viewModel.region)
            viewModel.onAppear()
            if selectedRealId == nil, let first = sortedReals.first {
                updateSelection(first, false)
            }
        }
        .onReceive(viewModel.$region.dropFirst()) { newRegion in
            cameraPosition = .region(newRegion)
        }
        .onChange(of: sortedReals.map(\.id)) { _ in
            if sortedReals.isEmpty {
                selectedRealId = nil
                activeExperience = nil
                return
            }
            if let currentId = selectedRealId,
               sortedReals.contains(where: { $0.id == currentId }) == false
            {
                selectedRealId = nil
            }
            if selectedRealId == nil, let first = sortedReals.first {
                updateSelection(first, false)
            }
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

private enum ActiveExperience: Identifiable {
    case real(items: [RealItem], currentId: UUID)
    case poi(RatedPOI)

    struct RealItem: Identifiable {
        let real: RealPost
        let user: User?

        var id: UUID { real.id }
    }

    var id: UUID {
        switch self {
        case let .real(_, currentId):
            return currentId
        case let .poi(rated):
            return rated.poi.id
        }
    }
}
