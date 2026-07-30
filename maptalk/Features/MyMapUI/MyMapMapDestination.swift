import CoreLocation
import MapKit
import SwiftUI

/// The private map reached from a MyMap list row.
///
/// It owns navigation back to the list, but the Journey interaction itself is
/// deliberately the same contract as MapTalk: a folder swaps the entire story
/// scope to its children, opens on the first child and unwinds one folder at a
/// time from the shared Journey header.
struct MyMapMapDestination: View {
    @Environment(\.dismiss) private var dismiss

    let records: [UserMapRecord]
    let selectedRecord: UserMapRecord
    let entryRegion: MKCoordinateRegion
    let journeyProvider: (UUID) -> JourneyPost?
    let userProvider: (UUID) -> User?

    @State private var flightController = MapFlightController()
    @State private var focusedRecord: UserMapRecord
    @State private var focusedJourney: JourneyPost?
    @State private var journeyStack: [JourneyPost] = []
    @State private var journeyEntryRecord: UserMapRecord?
    @State private var cameraPosition: MapCameraPosition
    @State private var currentRegion: MKCoordinateRegion
    @State private var mapSize: CGSize = .zero
    @State private var mapSafeAreaBottom: CGFloat = 0
    @State private var reelAlignTrigger = 0
    @StateObject private var capsulePresentation: MapExperiencePresentation
    @State private var didPrepareInitialRecord = false

    init(
        records: [UserMapRecord],
        selectedRecord: UserMapRecord,
        entryRegion: MKCoordinateRegion,
        journeyProvider: @escaping (UUID) -> JourneyPost?,
        userProvider: @escaping (UUID) -> User?
    ) {
        self.records = records
        self.selectedRecord = selectedRecord
        self.entryRegion = entryRegion
        self.journeyProvider = journeyProvider
        self.userProvider = userProvider
        _focusedRecord = State(initialValue: selectedRecord)
        _cameraPosition = State(initialValue: .region(entryRegion))
        _currentRegion = State(initialValue: entryRegion)
        _capsulePresentation = StateObject(
            wrappedValue: MapExperiencePresentation(compactDetent: Self.regularDetent)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            Map(position: $cameraPosition, interactionModes: .all) {
                ForEach(mapRecords) { record in
                    Annotation("", coordinate: record.coordinate) {
                        Button {
                            selectOnMap(
                                record,
                                size: geometry.size,
                                safeAreaBottom: geometry.safeAreaInsets.bottom
                            )
                        } label: {
                            marker(for: record)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(record.title)
                    }
                }
            }
            .mapStyle(.standard)
            .ignoresSafeArea()
            .onMapCameraChange(frequency: .onEnd) { context in
                currentRegion = context.region
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                header(size: geometry.size, safeAreaBottom: geometry.safeAreaInsets.bottom)
                    .padding(.vertical, 10)
            }
            .sheet(isPresented: $capsulePresentation.isPresented, onDismiss: {
                // A compact reset is an intentional native-sheet close/reopen.
                // Do not clear the Journey scope or its selection in that case.
                _ = capsulePresentation.didDismiss()
            }) {
                experienceCapsule
                    // Pager selection is intentionally excluded: changing page
                    // must not rebuild the whole capsule mid-swipe.
                    .id(capsulePresentation.contentRevision)
                    .mapExperienceSheetChrome(
                        compactDetent: Self.regularDetent,
                        selection: $capsulePresentation.detent
                    )
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .onAppear {
                mapSize = geometry.size
                mapSafeAreaBottom = geometry.safeAreaInsets.bottom
                prepareInitialRecord(size: geometry.size, safeAreaBottom: geometry.safeAreaInsets.bottom)
            }
            .onChangeCompat(of: geometry.size) { newSize in
                mapSize = newSize
                mapSafeAreaBottom = geometry.safeAreaInsets.bottom
            }
        }
    }

    @ViewBuilder
    private func header(size: CGSize, safeAreaBottom: CGFloat) -> some View {
        if let focusedJourney {
            let journeyScope = scope(for: focusedJourney)
            VStack(spacing: 6) {
                MapJourneyNavigationHeader(
                    path: journeyStack + [focusedJourney],
                    selectedJourneyId: focusedJourney.id,
                    onSelect: { journey in
                        focusJourneyFromBreadcrumb(
                            journey,
                            size: size,
                            safeAreaBottom: safeAreaBottom
                        )
                    },
                    onExit: {
                        exitJourneyFocus(size: size, safeAreaBottom: safeAreaBottom)
                    }
                )

                if journeyScope.storyItems.isEmpty == false {
                    RealStoriesRow(
                        items: journeyScope.storyItems,
                        selectedId: focusedRecord.id,
                        onSelectReal: { real in
                            guard let item = journeyScope.storyItem(for: real.id) else { return }
                            selectJourneyStory(item)
                        },
                        onSelectPOIGroup: { group in
                            guard let item = journeyScope.storyItem(for: group.id) else { return }
                            selectJourneyStory(item)
                        },
                        onSelectJourney: { _ in },
                        userProvider: userProvider,
                        alignTrigger: reelAlignTrigger,
                        displayMode: .content,
                        isUnseen: { _ in false }
                    )
                }
            }
            .padding(.horizontal, 16)
            .accessibilityIdentifier("mymap.journey-header")
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial.opacity(0.65))
                    .overlay(Color.white.opacity(0.06))
                    .mask {
                        LinearGradient(
                            colors: [.white, .white, .white.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
        } else {
            archiveHeader
        }
    }

    private var archiveHeader: some View {
        HStack(spacing: 12) {
            Button(action: dismiss.callAsFunction) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(.thinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color(.separator).opacity(0.22), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text("MyMap")
                    .font(.headline.weight(.semibold))
                Text("\(mapRecords.count) memories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private func marker(for record: UserMapRecord) -> some View {
        let isFocused = record.id == focusedRecord.id && (
            capsulePresentation.isPresented || focusedJourney != nil
        )

        switch record.kind {
        case let .poi(rated):
            UserMapMarker(category: rated.poi.category)
                .scaleEffect(isFocused ? 1.28 : 1)
                .shadow(color: isFocused ? Color.black.opacity(0.3) : .clear, radius: 7, y: 3)
        case let .reel(reel):
            RealMapThumbnail(
                real: reel,
                user: userProvider(reel.userId),
                size: isFocused ? 46 : 38,
                isSelected: isFocused
            )
        case .journey:
            ZStack {
                MemoryThumbnail(record: record, size: isFocused ? 46 : 40, cornerRadius: 12)
                Image(systemName: "folder.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white, lineWidth: isFocused ? 2.5 : 1.5)
            }
            .shadow(color: Color.black.opacity(isFocused ? 0.32 : 0.2), radius: 6, y: 3)
        }
    }

    private func prepareInitialRecord(size: CGSize, safeAreaBottom: CGFloat) {
        guard didPrepareInitialRecord == false else { return }
        didPrepareInitialRecord = true

        if case let .journey(journey) = selectedRecord.kind {
            enterJourney(
                journey,
                savesEntryRecord: false,
                size: size,
                safeAreaBottom: safeAreaBottom
            )
        } else {
            presentCapsule(for: selectedRecord)
            flyFromList(to: storyRegion(for: selectedRecord), cause: flightCause(for: selectedRecord))
        }
    }

    private func selectOnMap(_ record: UserMapRecord, size: CGSize, safeAreaBottom: CGFloat) {
        if case let .journey(journey) = record.kind {
            enterJourney(
                journey,
                savesEntryRecord: true,
                size: size,
                safeAreaBottom: safeAreaBottom
            )
            return
        }

        // A map pin changes the compact capsule without moving the map; this
        // is the same pin-tap rule used by MapTalk.
        presentCapsule(for: record)
    }

    private func enterJourney(
        _ journey: JourneyPost,
        savesEntryRecord: Bool,
        size: CGSize,
        safeAreaBottom: CGFloat
    ) {
        let isCurrentJourney = focusedJourney?.id == journey.id

        if focusedJourney == nil, savesEntryRecord, journeyEntryRecord == nil {
            journeyEntryRecord = focusedRecord
        }
        if let parent = focusedJourney, parent.id != journey.id {
            journeyStack.append(parent)
        }

        focusedJourney = journey
        focusJourneyCamera(journey, size: size, safeAreaBottom: safeAreaBottom)

        guard let firstChild = storyRecords(for: journey).first else {
            // An empty folder is still a valid scope, but it never renders the
            // Journey itself as a fake story card.
            focusedRecord = UserMapRecord(
                id: journey.id,
                timestamp: journey.createdAt,
                kind: .journey(journey)
            )
            capsulePresentation.dismiss()
            return
        }

        if isCurrentJourney,
           capsulePresentation.isPresented,
           capsulePresentation.isExpanded {
            // MapTalk keeps an already-open current Journey at its detent.
            focusedRecord = firstChild
        } else {
            presentCapsule(for: firstChild)
        }
        reelAlignTrigger &+= 1
    }

    private func focusJourneyFromBreadcrumb(
        _ journey: JourneyPost,
        size: CGSize,
        safeAreaBottom: CGFloat
    ) {
        if let index = journeyStack.firstIndex(where: { $0.id == journey.id }) {
            journeyStack = Array(journeyStack.prefix(upTo: index))
        }
        focusedJourney = journey
        focusJourneyCamera(journey, size: size, safeAreaBottom: safeAreaBottom)
        if let firstChild = storyRecords(for: journey).first {
            presentCapsule(for: firstChild)
        }
        reelAlignTrigger &+= 1
    }

    private func exitJourneyFocus(size: CGSize, safeAreaBottom: CGFloat) {
        if let parent = journeyStack.popLast() {
            focusedJourney = parent
            focusJourneyCamera(parent, size: size, safeAreaBottom: safeAreaBottom)
            if let firstChild = storyRecords(for: parent).first {
                presentCapsule(for: firstChild)
            } else {
                capsulePresentation.dismiss()
            }
            reelAlignTrigger &+= 1
            return
        }

        focusedJourney = nil
        guard let entryRecord = journeyEntryRecord else {
            // A Journey opened directly from the list has no parent capsule,
            // so its top exit returns to that list-level navigation layer.
            capsulePresentation.dismiss()
            dismiss()
            return
        }

        journeyEntryRecord = nil
        presentCapsule(for: entryRecord)
        flyFromList(to: storyRegion(for: entryRecord), cause: flightCause(for: entryRecord))
        reelAlignTrigger &+= 1
    }

    private func focusJourneyCamera(_ journey: JourneyPost, size: CGSize, safeAreaBottom: CGFloat) {
        guard let target = MapJourneyCamera.target(
            for: journey,
            size: size,
            safeAreaBottom: safeAreaBottom,
            compactFraction: Self.regularDetentFraction
        ) else {
            return
        }

        flightController.cancelActiveTransition()
        withAnimation(.easeInOut(duration: 0.35)) {
            cameraPosition = .camera(
                MapCamera(
                    centerCoordinate: target.region.center,
                    distance: target.distance,
                    heading: 0,
                    pitch: 0
                )
            )
        }
        currentRegion = target.region
    }

    private func flyFromList(to targetRegion: MKCoordinateRegion, cause: RegionChangeCause) {
        flightController.handleRegionChange(
            currentRegion: currentRegion,
            targetRegion: targetRegion,
            cause: cause,
            cameraPosition: $cameraPosition
        ) { region in
            currentRegion = region
        }
    }

    private func presentCapsule(for record: UserMapRecord) {
        focusedRecord = record
        capsulePresentation.presentNewContent()
    }

    @ViewBuilder
    private var experienceCapsule: some View {
        if sequenceItems.isEmpty {
            MapJourneyEmptyCapsule()
        } else {
            MapExperienceCapsule(
                pager: .init(items: sequenceItems),
                selection: sequenceSelection,
                isExpanded: capsulePresentation.isExpanded,
                onCollapsedTap: capsulePresentation.expand,
                journeyProvider: privateJourney(for:),
                userProvider: userProvider,
                onJourneyAvatarStackTap: openAttachedJourney
            )
        }
    }

    private func openAttachedJourney(_ journey: JourneyPost) {
        enterJourney(
            journey,
            savesEntryRecord: true,
            size: mapSize,
            safeAreaBottom: mapSafeAreaBottom
        )
    }

    /// Resolves only against the private folder catalog and active folder path;
    /// a MyMap Reel can never fall back to a public Journey source.
    private func privateJourney(for id: UUID) -> JourneyPost? {
        if focusedJourney?.id == id {
            return focusedJourney
        }
        if let pathJourney = journeyStack.first(where: { $0.id == id }) {
            return pathJourney
        }
        return journeyProvider(id)
    }

    private func scope(for journey: JourneyPost) -> MapJourneyScope {
        MapJourneyScope(journey: journey, userProvider: userProvider)
    }

    private func storyRecords(for journey: JourneyPost) -> [UserMapRecord] {
        scope(for: journey).storyItems.compactMap(record(for:))
    }

    private func record(for item: RealStoriesRow.StoryItem) -> UserMapRecord? {
        switch item.source {
        case let .real(real):
            return UserMapRecord(id: item.id, timestamp: item.timestamp, kind: .reel(real))
        case let .poi(group):
            return UserMapRecord(id: item.id, timestamp: item.timestamp, kind: .poi(group.ratedPOI))
        case .journey:
            return nil
        }
    }

    private var mapRecords: [UserMapRecord] {
        guard let focusedJourney else { return records }
        return storyRecords(for: focusedJourney)
    }

    private var sequenceItems: [ExperienceDetailView.SequencePager.Item] {
        if let focusedJourney {
            return scope(for: focusedJourney).sequenceItems
        }

        return mapRecords.compactMap { record in
            switch record.kind {
            case let .reel(reel):
                return .init(id: record.id, mode: .real(reel, userProvider(reel.userId)))
            case let .poi(rated):
                return .init(id: record.id, mode: .poi(rated))
            case .journey:
                return nil
            }
        }
    }

    private var sequenceSelection: Binding<UUID> {
        Binding(
            get: {
                if sequenceItems.contains(where: { $0.id == focusedRecord.id }) {
                    return focusedRecord.id
                }
                return sequenceItems.first?.id ?? focusedRecord.id
            },
            set: { identifier in
                guard let record = mapRecords.first(where: { $0.id == identifier }) else { return }
                selectFromCapsulePager(record)
            }
        )
    }

    private func selectFromCapsulePager(_ record: UserMapRecord) {
        focusedRecord = record
        reelAlignTrigger &+= 1
        let targetRegion = storyRegion(for: record)

        if capsulePresentation.isExpanded {
            // MapTalk keeps its content selection and map selection synchronized
            // without a cinematic transition behind the expanded sheet.
            currentRegion = targetRegion
            cameraPosition = .region(targetRegion)
            return
        }

        // Compact pager swipes remain in this one sheet; they only advance the
        // selected child and its matching map focus, never push another view.
        flightController.handleRegionChange(
            currentRegion: currentRegion,
            targetRegion: targetRegion,
            cause: flightCause(for: record),
            cameraPosition: $cameraPosition
        ) { region in
            currentRegion = region
        }
    }

    private func selectJourneyStory(_ item: RealStoriesRow.StoryItem) {
        guard let record = record(for: item) else { return }
        presentCapsule(for: record)
        flyFromList(to: storyRegion(for: record), cause: flightCause(for: record))
        reelAlignTrigger &+= 1
    }

    private func storyRegion(for record: UserMapRecord) -> MKCoordinateRegion {
        switch record.kind {
        case let .reel(reel):
            return MKCoordinateRegion(
                center: reel.center,
                latitudinalMeters: max(reel.radiusMeters, 3_500) * 2,
                longitudinalMeters: max(reel.radiusMeters, 3_500) * 2
            )
        case let .poi(rated):
            return MKCoordinateRegion(
                center: rated.poi.coordinate,
                latitudinalMeters: max(650, 1_800) * 2,
                longitudinalMeters: max(650, 1_800) * 2
            )
        case let .journey(journey):
            return MKCoordinateRegion(
                center: journey.coordinate,
                latitudinalMeters: 4_400,
                longitudinalMeters: 4_400
            )
        }
    }

    private func flightCause(for record: UserMapRecord) -> RegionChangeCause {
        switch record.kind {
        case .poi: .poi
        case .reel: .real
        case .journey: .journey
        }
    }

    private static let regularDetentFraction: CGFloat = 0.35
    private static let regularDetent = PresentationDetent.fraction(regularDetentFraction)
}
