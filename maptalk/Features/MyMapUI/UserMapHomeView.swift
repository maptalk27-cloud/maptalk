import MapKit
import SwiftUI
import UIKit

/// A single record collection rendered as either a chronological list or a map.
@MainActor
struct UserMapRecord: Identifiable {
    enum Kind {
        case poi(RatedPOI)
        case reel(RealPost)
        case journey(JourneyPost)
    }

    let id: UUID
    let timestamp: Date
    let kind: Kind

    var title: String {
        switch kind {
        case let .poi(poi):
            return poi.poi.name
        case let .reel(reel):
            return reel.message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Reel"
        case let .journey(journey):
            return journey.title
        }
    }

    var coordinate: CLLocationCoordinate2D {
        switch kind {
        case let .poi(poi): return poi.poi.coordinate
        case let .reel(reel): return reel.center
        case let .journey(journey): return journey.coordinate
        }
    }

    var isMapExperienceItem: Bool {
        switch kind {
        case .poi, .reel: true
        case .journey: false
        }
    }

    var cityName: String {
        if let locationLabel,
           let city = UserMapCity.city(from: locationLabel) {
            return city
        }
        return UserMapCity.label(for: coordinate)
    }

    private var locationLabel: String? {
        switch kind {
        case let .poi(poi):
            return PreviewData.locationLabel(for: poi.poi.id)
        case let .reel(reel):
            return PreviewData.locationLabel(for: reel.id)
        case let .journey(journey):
            return journey.reels.lazy.compactMap { PreviewData.locationLabel(for: $0.id) }.first
                ?? journey.pois.lazy.compactMap { PreviewData.locationLabel(for: $0.poi.id) }.first
        }
    }

    static func make(
        reels: [RealPost],
        footprints: [UserMapViewModel.Footprint]
    ) -> [UserMapRecord] {
        let reelRecords = reels.map {
            UserMapRecord(id: $0.id, timestamp: $0.createdAt, kind: .reel($0))
        }
        let poiRecords = footprints.map {
            UserMapRecord(
                id: $0.id,
                timestamp: $0.latestVisit ?? .distantPast,
                kind: .poi($0.ratedPOI)
            )
        }
        return (reelRecords + poiRecords)
            .sorted { $0.timestamp > $1.timestamp }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private enum JourneyOrganizerTarget: Hashable {
    case folder(UUID)
    case record(UUID)
}

private enum JourneyOrganizerCoordinateSpace {
    static let space: NamedCoordinateSpace = .named("mymap.journey-organizer")
}

private struct JourneyOrganizerTargetFramePreferenceKey: PreferenceKey {
    static var defaultValue: [JourneyOrganizerTarget: CGRect] = [:]

    static func reduce(
        value: inout [JourneyOrganizerTarget: CGRect],
        nextValue: () -> [JourneyOrganizerTarget: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

@MainActor
private struct JourneyOrganizerDrag {
    let record: UserMapRecord
    let reference: JourneyFolder.MemberReference
    var location: CGPoint
}

@MainActor
private struct JourneyOrganizerDrop: Identifiable {
    let id = UUID()
    let drag: JourneyOrganizerDrag
    let target: JourneyOrganizerTarget
}

/// A fresh Folder is created by a physical map gesture first, then receives
/// its human name without interrupting that spatial action.
private struct JourneyFolderRenameRequest: Identifiable {
    let folder: JourneyFolder

    var id: UUID { folder.id }
}

/// A `UILongPressGestureRecognizer` keeps one physical touch alive from the
/// hold that enters organize mode through its eventual drop. SwiftUI's
/// separate long-press and drag gestures cannot make that guarantee once the
/// map has its own pan recognizer in the hierarchy.
@available(iOS 18.0, *)
@MainActor
private struct MapOrganizerPressGesture: UIGestureRecognizerRepresentable {
    let isOrganizing: Bool
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = isOrganizing ? 0 : 0.55
        recognizer.allowableMovement = 14
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        return recognizer
    }

    func updateUIGestureRecognizer(
        _ recognizer: UILongPressGestureRecognizer,
        context: Context
    ) {
        // In organize mode a marker is a physical object: touching it picks
        // it up immediately. Outside that mode, a short touch stays a tap and
        // a moving touch can still pan the map.
        recognizer.minimumPressDuration = isOrganizing ? 0 : 0.55
        recognizer.allowableMovement = isOrganizing ? 44 : 14
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UILongPressGestureRecognizer,
        context: Context
    ) {
        let location = context.converter.location(in: JourneyOrganizerCoordinateSpace.space)
        switch recognizer.state {
        case .began:
            onBegan(location)
        case .changed:
            onChanged(location)
        case .ended:
            onEnded(location)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }
}

private extension UserMapRecord {
    var journeyMemberReference: JourneyFolder.MemberReference? {
        switch kind {
        case let .reel(reel): .reel(reel.id)
        case let .poi(rated): .poi(rated.id)
        case .journey: nil
        }
    }
}

struct UserMapHomeView: View {
    private enum Display: Equatable { case list, map }

    private struct JourneyAddContext: Identifiable {
        let id = UUID()
        let references: [JourneyFolder.MemberReference]
    }

    fileprivate enum RecordType: String, CaseIterable, Identifiable, Hashable {
        case poi = "POI"
        case reel = "Reel"

        var id: Self { self }
        var icon: String {
            switch self {
            case .poi: "mappin"
            case .reel: "play.rectangle"
            }
        }
    }

    fileprivate enum DatePreset: String, CaseIterable, Identifiable {
        case anyTime = "Any time"
        case today = "Today"
        case week = "Past week"
        case month = "Past month"
        case year = "Past year"
        case custom = "Custom range"

        var id: Self { self }
    }

    fileprivate struct FilterState: Equatable {
        var types = Set(RecordType.allCases)
        var cities: Set<String> = []
        var datePreset: DatePreset = .anyTime
        var customStartDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
        var customEndDate = Date.now

        var isDefault: Bool {
            types.count == RecordType.allCases.count
                && cities.isEmpty
                && datePreset == .anyTime
        }
    }

    fileprivate enum FilterPresentation: String, Identifiable {
        case all
        case type
        case date
        case city

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "Filter memories"
            case .type: "Type"
            case .date: "Date"
            case .city: "Cities"
            }
        }
    }

    let user: User
    let region: MKCoordinateRegion
    let records: [UserMapRecord]
    /// Private folder catalog. It resolves an attached or nested Journey but
    /// does not decide which folders appear at the MyMap root.
    let journeyProvider: (UUID) -> JourneyPost?
    /// Local-only collections. These are deliberately separate from the
    /// chronological POI / Reel records above.
    let journeyFolders: [JourneyFolder]
    let reels: [RealPost]
    let footprints: [UserMapViewModel.Footprint]
    let canEditJourneyFolders: Bool
    let onCreateJourneyFolder: (String, [JourneyFolder.MemberReference]) -> JourneyFolder?
    let onSaveJourneyFolder: (JourneyFolder) -> Void
    let onDeleteJourneyFolder: (UUID) -> Void
    let userProvider: (UUID) -> User?

    @State private var display: Display = .list
    /// The map stays mounted beneath the archive, but its first presentation
    /// should still frame the available memories. Later List ↔ Map switches
    /// preserve the person's manually chosen viewport.
    @State private var hasPresentedMap = false
    @State private var searchText = ""
    @State private var filters = FilterState()
    @State private var filterDraft = FilterState()
    @State private var filterPresentation: FilterPresentation?
    @State private var mapSelectedRecord: UserMapRecord?
    /// A record opened from List creates a temporary map focus that has a
    /// clear, local way back to the archive.
    @State private var listFocusRecordID: UUID?
    @State private var listReturnRecordID: UUID?
    @State private var mapFocusedJourney: JourneyPost?
    @State private var mapJourneyStack: [JourneyPost] = []
    @State private var mapJourneyEntryRecord: UserMapRecord?
    @State private var mapJourneyEntryRegion: MKCoordinateRegion?
    @StateObject private var mapCapsulePresentation: MapExperiencePresentation
    @State private var mapFlightController = MapFlightController()
    @State private var cameraPosition: MapCameraPosition
    @State private var currentMapRegion: MKCoordinateRegion
    @State private var mapSize: CGSize = .zero
    @State private var mapSafeAreaBottom: CGFloat = 0
    @State private var mapOverlayRevision = 0
    @State private var mapReelAlignTrigger = 0
    @State private var journeyFolderRoute: JourneyFolder?
    @State private var journeyAddContext: JourneyAddContext?
    @State private var journeyFolderRenameRequest: JourneyFolderRenameRequest?
    @State private var isSelectingMemories = false
    @State private var selectedMemoryIDs: Set<UUID> = []
    @State private var isOrganizingMapJourneys = false
    @State private var journeyOrganizerDrag: JourneyOrganizerDrag?
    @State private var journeyOrganizerDrop: JourneyOrganizerDrop?
    @State private var isJourneyOrganizerDropSettling = false
    @State private var journeyOrganizerCompletedTarget: JourneyOrganizerTarget?
    @State private var journeyOrganizerHoveredTarget: JourneyOrganizerTarget?
    @State private var journeyOrganizerTargetFrames: [JourneyOrganizerTarget: CGRect] = [:]
    @State private var journeyOrganizerSelectionFeedback = UISelectionFeedbackGenerator()
    @FocusState private var isSearchFocused: Bool

    init(
        user: User,
        region: MKCoordinateRegion,
        records: [UserMapRecord],
        journeyProvider: @escaping (UUID) -> JourneyPost?,
        journeyFolders: [JourneyFolder] = [],
        reels: [RealPost] = [],
        footprints: [UserMapViewModel.Footprint] = [],
        canEditJourneyFolders: Bool = false,
        onCreateJourneyFolder: @escaping (String, [JourneyFolder.MemberReference]) -> JourneyFolder? = { _, _ in nil },
        onSaveJourneyFolder: @escaping (JourneyFolder) -> Void = { _ in },
        onDeleteJourneyFolder: @escaping (UUID) -> Void = { _ in },
        userProvider: @escaping (UUID) -> User?
    ) {
        self.user = user
        self.region = region
        self.records = records
        self.journeyProvider = journeyProvider
        self.journeyFolders = journeyFolders
        self.reels = reels
        self.footprints = footprints
        self.canEditJourneyFolders = canEditJourneyFolders
        self.onCreateJourneyFolder = onCreateJourneyFolder
        self.onSaveJourneyFolder = onSaveJourneyFolder
        self.onDeleteJourneyFolder = onDeleteJourneyFolder
        self.userProvider = userProvider
        _cameraPosition = State(initialValue: .region(region))
        _currentMapRegion = State(initialValue: region)
        _mapCapsulePresentation = StateObject(
            wrappedValue: MapExperiencePresentation(compactDetent: Self.mapCapsuleCompactDetent)
        )
    }

    var body: some View {
        ZStack {
            // MyMap has one map canvas. The list is an opaque reading layer
            // above it rather than a separate root screen, so returning to
            // Map keeps its camera, selection, and interaction state intact.
            mapContent

            if display == .list {
                listContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: display)
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if display == .map, isOrganizingMapJourneys {
                    mapJourneyDock
                        .padding(.horizontal, 16)
                        .padding(.bottom, 54)
                }

                if display == .list, isSelectingMemories, selectedMemoryIDs.isEmpty == false {
                    addSelectionToJourneyButton
                }

                if mapJourneyIsActive == false, isOrganizingMapJourneys == false {
                    viewToggle
                        // Keep the List/Map control above the scroll view's
                        // NavigationLinks; otherwise its visual capsule can be
                        // tapped through into an archive row.
                        .zIndex(100)
                }
            }
            // The control belongs to MyMap, not either presentation mode.
            .padding(.bottom, isOrganizingMapJourneys ? 10 : 18)
        }
        .overlay {
            GeometryReader { proxy in
                if let drag = journeyOrganizerDrag {
                    MapJourneyDragPreview(
                        record: drag.record,
                        user: mapJourneyDragPreviewUser(for: drag.record)
                    )
                    .position(mapJourneyDragPreviewPosition(for: drag, in: proxy))
                    .transition(.scale(scale: 0.84).combined(with: .opacity))
                    .animation(
                        .spring(response: 0.24, dampingFraction: 0.76),
                        value: journeyOrganizerHoveredTarget
                    )
                } else if let drop = journeyOrganizerDrop {
                    MapJourneyDragPreview(
                        record: drop.drag.record,
                        user: mapJourneyDragPreviewUser(for: drop.drag.record)
                    )
                    .position(mapJourneyDropPosition(for: drop, in: proxy))
                    .scaleEffect(isJourneyOrganizerDropSettling ? 0.32 : 1)
                    .opacity(isJourneyOrganizerDropSettling ? 0.04 : 1)
                    .animation(
                        .snappy(duration: 0.2, extraBounce: 0.08),
                        value: isJourneyOrganizerDropSettling
                    )
                }
            }
            .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if display == .map, mapFocusedJourney != nil {
                mapJourneyControls
            } else if isOrganizingMapJourneys == false {
                archiveControls
            }
        }
        .navigationTitle("MyMap")
        .navigationBarTitleDisplayMode(.inline)
        // A root Map is still MyMap. Only a focused Journey replaces this
        // identity with its own breadcrumb header.
        .toolbar(mapJourneyIsActive ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if isListRecordFocusActive {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: returnToList) {
                        Label("List", systemImage: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("Return to list")
                }
            }

            if display == .list, canEditJourneyFolders {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelectingMemories ? "Done" : "Select") {
                        toggleMemorySelection()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }

            if display == .map, mapFocusedJourney == nil, isOrganizingMapJourneys {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: finishMapJourneyOrganization) {
                        Text("Done")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.black, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $filterPresentation) { presentation in
            UserMapFilterSheet(
                presentation: presentation,
                cities: availableCities,
                filters: $filterDraft,
                resultCount: filteredRecords(using: filterDraft).count,
                onApply: {
                    applyFilters(filterDraft)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $journeyAddContext) { context in
            JourneyFolderPickerSheet(
                folders: journeyFolders,
                memoryCount: context.references.count,
                onSelect: { folderID in
                    append(context.references, toJourneyFolder: folderID)
                    finishMemorySelection()
                },
                onCreate: { title in
                    let folder = onCreateJourneyFolder(title, context.references)
                    finishMemorySelection()
                    guard let folder else { return }
                    DispatchQueue.main.async {
                        journeyFolderRoute = folder
                    }
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $journeyFolderRenameRequest) { request in
            JourneyFolderNamingSheet(
                folder: request.folder,
                onSave: onSaveJourneyFolder
            )
            .presentationDetents([.height(264)])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(item: $journeyFolderRoute) { folder in
            JourneyFolderDetailView(
                folder: folder,
                reels: reels,
                footprints: footprints,
                onSave: onSaveJourneyFolder,
                onDelete: onDeleteJourneyFolder
            )
        }
        .sheet(isPresented: $mapCapsulePresentation.isPresented, onDismiss: {
            guard mapCapsulePresentation.didDismiss() == false else { return }
            if let journey = mapFocusedJourney {
                // MapTalk keeps the folder alive after a user dismisses its
                // capsule; the next map interaction begins from its first
                // child instead of falling back to the archive pager.
                mapSelectedRecord = storyRecords(for: journey).first
            } else {
                mapSelectedRecord = nil
            }
        }) {
            if mapSelectedRecord != nil {
                mapCapsule
                    // A pager swipe must retain the same native sheet and its
                    // in-flight gesture; selection is content state, not view identity.
                    .id(mapCapsulePresentation.contentRevision)
                    .accessibilityIdentifier("mymap.compact-capsule")
                    .mapExperienceSheetChrome(
                        compactDetent: Self.mapCapsuleCompactDetent,
                        selection: $mapCapsulePresentation.detent
                    )
            }
        }
        .onPreferenceChange(JourneyOrganizerTargetFramePreferenceKey.self) { frames in
            journeyOrganizerTargetFrames = frames
        }
        // Both the map markers and the folder dock participate in one drag.
        // Their hit frames must therefore use exactly the same coordinate
        // space as the UIKit recognizer, rather than each view's screen/global
        // interpretation.
        .coordinateSpace(JourneyOrganizerCoordinateSpace.space)
    }

    private var filteredRecords: [UserMapRecord] {
        filteredRecords(using: filters)
    }

    private func filteredRecords(using filter: FilterState) -> [UserMapRecord] {
        records.filter { record in
            guard let type = recordType(for: record), filter.types.contains(type) else { return false }
            guard filter.cities.isEmpty || filter.cities.contains(record.cityName) else { return false }
            guard matchesDate(record.timestamp, using: filter) else { return false }
            guard searchText.isEmpty == false else { return true }
            return record.title.localizedCaseInsensitiveContains(searchText)
                || record.cityName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var availableCities: [String] {
        Array(Set(records.map(\.cityName))).sorted()
    }

    private var hasActiveFilters: Bool {
        filters.isDefault == false
    }

    private func recordType(for record: UserMapRecord) -> RecordType? {
        switch record.kind {
        case .poi: .poi
        case .reel: .reel
        case .journey: nil
        }
    }

    private func matchesDate(_ date: Date, using filter: FilterState) -> Bool {
        let calendar = Calendar.current
        switch filter.datePreset {
        case .anyTime:
            return true
        case .today:
            return calendar.isDateInToday(date)
        case .week:
            return date >= (calendar.date(byAdding: .day, value: -7, to: .now) ?? .distantPast)
        case .month:
            return date >= (calendar.date(byAdding: .month, value: -1, to: .now) ?? .distantPast)
        case .year:
            return date >= (calendar.date(byAdding: .year, value: -1, to: .now) ?? .distantPast)
        case .custom:
            let start = calendar.startOfDay(for: min(filter.customStartDate, filter.customEndDate))
            let endDay = calendar.startOfDay(for: max(filter.customStartDate, filter.customEndDate))
            let end = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            return date >= start && date < end
        }
    }

    private var groupedRecords: [(String, [UserMapRecord])] {
        Dictionary(grouping: filteredRecords, by: sectionTitle(for:))
            .map { ($0.key, $0.value) }
            .sorted { lhs, rhs in
                guard let left = lhs.1.first?.timestamp,
                      let right = rhs.1.first?.timestamp else { return false }
                return left > right
            }
    }

    /// Filters describe the memory stream. The organizer stays visible only
    /// in the natural browse state so it never masquerades as a third record
    /// type in a filtered result.
    private var shouldShowJourneyShelf: Bool {
        canEditJourneyFolders && searchText.isEmpty && filters.isDefault
    }

    private var selectedMemoryReferences: [JourneyFolder.MemberReference] {
        records.compactMap { record in
            guard selectedMemoryIDs.contains(record.id) else { return nil }
            return record.journeyMemberReference
        }
    }

    private var addSelectionToJourneyButton: some View {
        Button {
            let references = selectedMemoryReferences
            guard references.isEmpty == false else { return }
            journeyAddContext = JourneyAddContext(references: references)
        } label: {
            Label(
                "Add \(selectedMemoryReferences.count) to Journey",
                systemImage: "folder.badge.plus"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.9), in: Capsule())
            .shadow(color: Color.black.opacity(0.2), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mymap.add-to-journey")
    }

    private func toggleMemorySelection() {
        isSearchFocused = false
        if isSelectingMemories {
            finishMemorySelection()
        } else {
            isSelectingMemories = true
        }
    }

    private func toggleMemorySelection(_ record: UserMapRecord) {
        guard record.isMapExperienceItem else { return }
        if selectedMemoryIDs.contains(record.id) {
            selectedMemoryIDs.remove(record.id)
        } else {
            selectedMemoryIDs.insert(record.id)
        }
    }

    private func finishMemorySelection() {
        journeyAddContext = nil
        selectedMemoryIDs.removeAll()
        isSelectingMemories = false
    }

    private func enterMapJourneyOrganization() {
        guard canEditJourneyFolders,
              display == .map,
              mapFocusedJourney == nil else {
            return
        }

        guard isOrganizingMapJourneys == false else { return }
        isSearchFocused = false
        // Organizing is a distinct, quiet state. A browsing capsule or search
        // controls make the map feel like an overlay instead of a workspace.
        mapSelectedRecord = nil
        mapCapsulePresentation.dismiss()
        journeyOrganizerTargetFrames = [:]
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            isOrganizingMapJourneys = true
        }
        journeyOrganizerSelectionFeedback.prepare()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func finishMapJourneyOrganization() {
        journeyOrganizerDrag = nil
        journeyOrganizerDrop = nil
        isJourneyOrganizerDropSettling = false
        journeyOrganizerCompletedTarget = nil
        journeyOrganizerHoveredTarget = nil
        journeyOrganizerTargetFrames = [:]
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            isOrganizingMapJourneys = false
        }
    }

    private func beginMapJourneyDrag(_ record: UserMapRecord, at location: CGPoint) {
        guard isOrganizingMapJourneys,
              let reference = record.journeyMemberReference else {
            return
        }

        if journeyOrganizerDrag?.record.id == record.id {
            updateMapJourneyDrag(record, at: location)
            return
        }

        journeyOrganizerDrag = JourneyOrganizerDrag(
            record: record,
            reference: reference,
            location: location
        )
        updateMapJourneyDrag(record, at: location)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func updateMapJourneyDrag(_ record: UserMapRecord, at location: CGPoint) {
        guard var drag = journeyOrganizerDrag,
              drag.record.id == record.id else {
            return
        }
        drag.location = location
        journeyOrganizerDrag = drag

        let nextTarget = journeyOrganizerTarget(at: location, excluding: record.id)
        guard nextTarget != journeyOrganizerHoveredTarget else { return }

        journeyOrganizerHoveredTarget = nextTarget
        if nextTarget != nil {
            journeyOrganizerSelectionFeedback.selectionChanged()
            journeyOrganizerSelectionFeedback.prepare()
        }
    }

    private func endMapJourneyDrag(_ record: UserMapRecord, at location: CGPoint) {
        updateMapJourneyDrag(record, at: location)
        guard let drag = journeyOrganizerDrag,
              drag.record.id == record.id,
              let target = journeyOrganizerHoveredTarget else {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                journeyOrganizerDrag = nil
                journeyOrganizerHoveredTarget = nil
            }
            return
        }

        // Let the lifted marker visibly settle into its target before the
        // underlying data changes. The touch feels like putting an object
        // away, rather than an immediate list mutation.
        let drop = JourneyOrganizerDrop(drag: drag, target: target)
        journeyOrganizerDrag = nil
        journeyOrganizerHoveredTarget = nil
        journeyOrganizerCompletedTarget = target
        journeyOrganizerDrop = drop
        isJourneyOrganizerDropSettling = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        DispatchQueue.main.async {
            guard journeyOrganizerDrop?.id == drop.id else { return }
            withAnimation(.snappy(duration: 0.2, extraBounce: 0.08)) {
                isJourneyOrganizerDropSettling = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard journeyOrganizerDrop?.id == drop.id else { return }
            completeMapJourneyDrop(drop)
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                journeyOrganizerDrop = nil
                isJourneyOrganizerDropSettling = false
                journeyOrganizerCompletedTarget = nil
            }
        }
    }

    private func cancelMapJourneyDrag(_ record: UserMapRecord) {
        guard journeyOrganizerDrag?.record.id == record.id else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
            journeyOrganizerDrag = nil
            journeyOrganizerHoveredTarget = nil
        }
    }

    private func completeMapJourneyDrop(_ drop: JourneyOrganizerDrop) {
        switch drop.target {
        case let .folder(folderID):
            append([drop.drag.reference], toJourneyFolder: folderID)

        case let .record(recordID):
            guard recordID != drop.drag.record.id,
                  let other = mapRecords.first(where: { $0.id == recordID }),
                  let otherReference = other.journeyMemberReference else {
                return
            }
            if let folder = createJourney(with: [otherReference, drop.drag.reference]) {
                journeyFolderRenameRequest = JourneyFolderRenameRequest(folder: folder)
            }
        }
    }

    private func journeyOrganizerTarget(
        at location: CGPoint,
        excluding sourceRecordID: UUID
    ) -> JourneyOrganizerTarget? {
        // Once a target has caught the marker, give it a larger exit radius.
        // This avoids the harsh on/off flicker caused by sampling a moving
        // finger around a target boundary.
        if let hovered = journeyOrganizerHoveredTarget,
           targetContains(
                hovered,
                location: location,
                excluding: sourceRecordID,
                padding: hoveredExitPadding(for: hovered)
           ) {
            return hovered
        }

        // A drop should feel forgiving: folders take priority in their dock,
        // while map pins receive a slightly larger magnetic catchment area.
        let folderCandidates = journeyOrganizerTargetFrames.compactMap { target, frame -> (JourneyOrganizerTarget, CGFloat)? in
            switch target {
            case .folder:
                let expandedFrame = frame.insetBy(dx: -12, dy: -12)
                guard expandedFrame.contains(location) else { return nil }
                return (target, distanceSquared(from: location, to: .init(x: frame.midX, y: frame.midY)))
            case .record:
                return nil
            }
        }
        if let folderTarget = folderCandidates.min(by: { $0.1 < $1.1 })?.0 {
            return folderTarget
        }

        let recordCandidates = journeyOrganizerTargetFrames.compactMap { target, frame -> (JourneyOrganizerTarget, CGFloat)? in
            guard case let .record(recordID) = target,
                  recordID != sourceRecordID else {
                return nil
            }

            let expandedFrame = frame.insetBy(dx: -22, dy: -22)
            guard expandedFrame.contains(location) else { return nil }
            return (target, distanceSquared(from: location, to: .init(x: frame.midX, y: frame.midY)))
        }
        return recordCandidates.min(by: { $0.1 < $1.1 })?.0
    }

    private func targetContains(
        _ target: JourneyOrganizerTarget,
        location: CGPoint,
        excluding sourceRecordID: UUID,
        padding: CGFloat
    ) -> Bool {
        guard let frame = journeyOrganizerTargetFrames[target] else { return false }

        switch target {
        case .folder:
            return frame.insetBy(dx: -padding, dy: -padding).contains(location)
        case let .record(recordID):
            guard recordID != sourceRecordID else { return false }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let dx = location.x - center.x
            let dy = location.y - center.y
            let radius = max(frame.width, frame.height) / 2 + padding
            return (dx * dx) + (dy * dy) <= radius * radius
        }
    }

    private func hoveredExitPadding(for target: JourneyOrganizerTarget) -> CGFloat {
        switch target {
        case .folder: 24
        case .record: 34
        }
    }

    private func distanceSquared(from point: CGPoint, to center: CGPoint) -> CGFloat {
        let dx = point.x - center.x
        let dy = point.y - center.y
        return (dx * dx) + (dy * dy)
    }

    private func mapJourneyDragPreviewUser(for record: UserMapRecord) -> User? {
        guard case let .reel(reel) = record.kind else { return nil }
        return userProvider(reel.userId)
    }

    private func mapJourneyDragPreviewPosition(
        for drag: JourneyOrganizerDrag,
        in proxy: GeometryProxy
    ) -> CGPoint {
        let rootFrame = proxy.frame(in: JourneyOrganizerCoordinateSpace.space)
        let pointerPosition = CGPoint(
            x: drag.location.x - rootFrame.minX,
            y: drag.location.y - rootFrame.minY - 34
        )

        guard let target = journeyOrganizerHoveredTarget,
              let targetFrame = journeyOrganizerTargetFrames[target] else {
            return pointerPosition
        }

        let targetCenter = CGPoint(
            x: targetFrame.midX - rootFrame.minX,
            y: targetFrame.midY - rootFrame.minY
        )

        // A real object stays under the person's finger. The target can make
        // a small magnetic pull, but the dragged marker must never teleport
        // to the target's center like an overlay card.
        let dx = targetCenter.x - pointerPosition.x
        let dy = targetCenter.y - pointerPosition.y
        let distance = max(sqrt(dx * dx + dy * dy), 0.001)
        let maximumPull: CGFloat = {
            switch target {
            case .record: 12
            case .folder: 14
            }
        }()
        let pull = min(maximumPull, distance * 0.2)
        return CGPoint(
            x: pointerPosition.x + (dx / distance) * pull,
            y: pointerPosition.y + (dy / distance) * pull
        )
    }

    private func mapJourneyDropPosition(
        for drop: JourneyOrganizerDrop,
        in proxy: GeometryProxy
    ) -> CGPoint {
        let rootFrame = proxy.frame(in: JourneyOrganizerCoordinateSpace.space)
        let pointerPosition = CGPoint(
            x: drop.drag.location.x - rootFrame.minX,
            y: drop.drag.location.y - rootFrame.minY - 34
        )

        guard isJourneyOrganizerDropSettling,
              let targetFrame = journeyOrganizerTargetFrames[drop.target] else {
            return pointerPosition
        }

        return CGPoint(
            x: targetFrame.midX - rootFrame.minX,
            y: targetFrame.midY - rootFrame.minY
        )
    }

    private func createJourney(
        with references: [JourneyFolder.MemberReference]
    ) -> JourneyFolder? {
        let uniqueReferences = references.reduce(into: [JourneyFolder.MemberReference]()) { result, reference in
            if result.contains(reference) == false {
                result.append(reference)
            }
        }
        guard uniqueReferences.isEmpty == false else { return nil }
        return onCreateJourneyFolder("Untitled Journey", uniqueReferences)
    }

    private func append(
        _ references: [JourneyFolder.MemberReference],
        toJourneyFolder folderID: UUID
    ) {
        guard var folder = journeyFolders.first(where: { $0.id == folderID }) else { return }
        for reference in references where folder.memberReferences.contains(reference) == false {
            folder.memberReferences.append(reference)
        }
        onSaveJourneyFolder(folder)
    }

    private var listContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26, pinnedViews: .sectionHeaders) {
                    journeyShelfContent
                    archiveEmptyState

                    ForEach(groupedRecords, id: \.0) { section in
                        archiveSection(section)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, isSelectingMemories && selectedMemoryIDs.isEmpty == false ? 158 : 94)
            }
            .onAppear {
                restoreListPosition(using: proxy)
            }
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var journeyShelfContent: some View {
        if shouldShowJourneyShelf {
            JourneyFolderShelf(
                folders: journeyFolders,
                reels: reels,
                footprints: footprints,
                onOpen: { folder in
                    journeyFolderRoute = folder
                },
                onCreate: {
                    journeyAddContext = JourneyAddContext(references: [])
                }
            )
            .padding(.bottom, 2)
        }
    }

    /// A Journey has no coordinate. In arrange mode it lives in a compact,
    /// horizontally-scrollable photo rail above the tab bar rather than as a
    /// map pin. The rail stays available throughout the session, like the
    /// familiar iPhone Home Screen dock.
    @ViewBuilder
    private var mapJourneyDock: some View {
        if isOrganizingMapJourneys, journeyFolders.isEmpty == false {
            mapJourneyDropDock
        }
    }

    @ViewBuilder
    private var mapJourneyDropDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            mapJourneyDropDockTiles
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("mymap.journey-dock")
    }

    private var mapJourneyDropDockTiles: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(journeyFolders) { folder in
                mapJourneyFolderTarget(
                    folder,
                    records: mapJourneyRecords(for: folder)
                )
            }
        }
    }

    @ViewBuilder
    private func mapJourneyFolderTarget(
        _ folder: JourneyFolder,
        records: [UserMapRecord]
    ) -> some View {
        let target = JourneyOrganizerTarget.folder(folder.id)
        let isDropTarget = isOrganizingMapJourneys && (
            journeyOrganizerHoveredTarget == target || journeyOrganizerCompletedTarget == target
        )
        let hasOtherActiveTarget = journeyOrganizerHoveredTarget != nil && isDropTarget == false
        let tile = VStack(spacing: 6) {
            MapJourneyFolderDockCover(
                records: records,
                isDropTarget: isDropTarget,
                size: 64
            )
            .scaleEffect(isDropTarget ? 1.1 : 1, anchor: .bottom)
            .offset(y: isDropTarget ? -5 : 0)

            Text(folder.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.82)
                .frame(width: 70, height: 24, alignment: .top)
                .shadow(color: Color.white.opacity(0.96), radius: 2, y: 1)
        }
        .frame(width: 70)
        .opacity(hasOtherActiveTarget ? 0.62 : 1)
        .shadow(
            color: Color.black.opacity(isDropTarget ? 0.24 : 0),
            radius: isDropTarget ? 12 : 0,
            y: isDropTarget ? 7 : 0
        )
        .animation(.spring(response: 0.24, dampingFraction: 0.76), value: journeyOrganizerHoveredTarget)
        .background(mapJourneyTargetFrame(target))

        tile
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Journey folder: \(folder.title)")
            .accessibilityValue("\(folder.memberReferences.count) memories")
            .accessibilityIdentifier("mymap.map-journey-folder.\(folder.id.uuidString)")
    }

    private func mapJourneyRecords(for folder: JourneyFolder) -> [UserMapRecord] {
        folder.memberReferences.compactMap { reference in
            switch reference {
            case let .reel(id):
                guard let reel = reels.first(where: { $0.id == id }) else { return nil }
                return UserMapRecord(id: reel.id, timestamp: reel.createdAt, kind: .reel(reel))

            case let .poi(id):
                guard let footprint = footprints.first(where: { $0.id == id }) else { return nil }
                return UserMapRecord(
                    id: footprint.id,
                    timestamp: footprint.latestVisit ?? .distantPast,
                    kind: .poi(footprint.ratedPOI)
                )
            }
        }
    }

    private func mapJourneyTargetFrame(_ target: JourneyOrganizerTarget) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: JourneyOrganizerTargetFramePreferenceKey.self,
                value: isOrganizingMapJourneys
                    ? [target: proxy.frame(in: JourneyOrganizerCoordinateSpace.space)]
                    : [:]
            )
        }
    }

    private func mapJourneyWiggle(for id: UUID) -> Double {
        id.uuidString.hashValue.isMultiple(of: 2) ? 1 : -1
    }


    @ViewBuilder
    private var archiveEmptyState: some View {
        if filteredRecords.isEmpty {
            ContentUnavailableView(
                "No memories found",
                systemImage: "magnifyingglass",
                description: Text("Try a different search or filter.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        }
    }

    private func archiveSection(_ section: (String, [UserMapRecord])) -> some View {
        Section {
            VStack(spacing: 0) {
                ForEach(section.1.indices, id: \.self) { index in
                    archiveRecordRow(section.1[index])
                        .id(section.1[index].id)

                    if index < section.1.count - 1 {
                        Divider()
                            .padding(.leading, isSelectingMemories ? 38 : 76)
                    }
                }
            }
        } header: {
            ArchiveDateHeader(
                title: section.0,
                count: section.1.count,
                date: section.1.first?.timestamp ?? .now
            )
            .background(Color(.systemBackground))
        }
    }

    @ViewBuilder
    private func archiveRecordRow(_ record: UserMapRecord) -> some View {
        if isSelectingMemories {
            Button {
                toggleMemorySelection(record)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedMemoryIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selectedMemoryIDs.contains(record.id) ? Color(Theme.neonPrimary) : Color.secondary)
                    UserMapRecordCard(record: record)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Button {
                openRecordFromList(record)
            } label: {
                UserMapRecordCard(record: record)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mymap.list-record.\(record.id.uuidString)")
        }
    }

    private var mapContent: some View {
        MapReader { mapProxy in
            GeometryReader { geometry in
                Map(
                    position: $cameraPosition,
                    // Empty map space remains fully explorable in organize
                    // mode. Once a marker is actually lifted, freeze the
                    // canvas until it is dropped so the target stays put.
                    interactionModes: journeyOrganizerDrag == nil ? .all : []
                ) {
                    ForEach(mapRecords) { record in
                        Annotation("", coordinate: record.coordinate) {
                            // MapKit owns spatial rendering; interaction is a
                            // stable overlay, so a long press never replaces
                            // the annotation beneath the user's finger.
                            mapMarkerVisual(for: record)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .overlay {
                    mapOrganizerHitLayer(
                        using: mapProxy,
                        size: geometry.size,
                        safeAreaBottom: geometry.safeAreaInsets.bottom
                    )
                }
                .ignoresSafeArea(edges: .bottom)
                .onMapCameraChange(frequency: .continuous) { context in
                    currentMapRegion = context.region
                    mapOverlayRevision &+= 1
                }
                .onAppear {
                    mapSize = geometry.size
                    mapSafeAreaBottom = geometry.safeAreaInsets.bottom
                }
                .onChangeCompat(of: geometry.size) { newSize in
                    mapSize = newSize
                    mapSafeAreaBottom = geometry.safeAreaInsets.bottom
                }
            }
        }
    }

    @ViewBuilder
    private func mapOrganizerHitLayer(
        using mapProxy: MapProxy,
        size: CGSize,
        safeAreaBottom: CGFloat
    ) -> some View {
        // Reading the revision keeps the hit layer aligned while the person
        // pans the map. The layer has no full-screen hit shape, so blank map
        // space continues straight through to MapKit.
        let _ = mapOverlayRevision

        ForEach(mapRecords) { record in
            if let point = mapProxy.convert(record.coordinate, to: .local),
               isVisibleMapPoint(point, in: size) {
                mapOrganizerMarkerHitTarget(
                    for: record,
                    size: size,
                    safeAreaBottom: safeAreaBottom
                )
                .position(point)
            }
        }
    }

    private func isVisibleMapPoint(_ point: CGPoint, in size: CGSize) -> Bool {
        let hitRadius: CGFloat = 36
        return point.x >= -hitRadius && point.x <= size.width + hitRadius
            && point.y >= -hitRadius && point.y <= size.height + hitRadius
    }

    @ViewBuilder
    private func mapOrganizerMarkerHitTarget(
        for record: UserMapRecord,
        size: CGSize,
        safeAreaBottom: CGFloat
    ) -> some View {
        // This control deliberately stays structurally identical before and
        // after edit mode begins. Replacing it midway through a hold is what
        // made the previous interaction require a release before dragging.
        Button {
            guard isOrganizingMapJourneys == false,
                  journeyOrganizerDrag == nil else {
                return
            }
            selectOnMap(record, size: size, safeAreaBottom: safeAreaBottom)
        } label: {
            Circle()
                .fill(Color.clear)
                .frame(width: 64, height: 64)
                .contentShape(Circle())
                .gesture(
                    MapOrganizerPressGesture(
                        isOrganizing: isOrganizingMapJourneys,
                        onBegan: { location in
                            guard record.journeyMemberReference != nil else { return }
                            if isOrganizingMapJourneys == false {
                                enterMapJourneyOrganization()
                            }
                            beginMapJourneyDrag(record, at: location)
                        },
                        onChanged: { location in
                            updateMapJourneyDrag(record, at: location)
                        },
                        onEnded: { location in
                            endMapJourneyDrag(record, at: location)
                        },
                        onCancelled: {
                            cancelMapJourneyDrag(record)
                        }
                    )
                )
        }
        .buttonStyle(.plain)
        .background(mapMarkerTargetFrame(for: record))
        .accessibilityLabel(record.title)
        .accessibilityHint(
            isOrganizingMapJourneys
                ? "Drag into another memory or Journey"
                : "Double tap to open. Long press to organize."
        )
        .accessibilityIdentifier("mymap.map-marker.\(record.id.uuidString)")
    }

    private func mapMarkerVisual(for record: UserMapRecord) -> some View {
        let recordTarget = JourneyOrganizerTarget.record(record.id)
        let isDropTarget = journeyOrganizerHoveredTarget == recordTarget
            || journeyOrganizerCompletedTarget == recordTarget
        let isDragged = journeyOrganizerDrag?.record.id == record.id

        return mapMarker(for: record)
            .contentShape(Rectangle())
            .background {
                if isDropTarget {
                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 58, height: 58)
                        .overlay {
                            Circle()
                                .stroke(Color(Theme.neonPrimary), lineWidth: 2)
                        }
                        .shadow(color: Color.black.opacity(0.2), radius: 10, y: 4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isDropTarget {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.black, in: Circle())
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .offset(x: 6, y: 6)
                }
            }
            .rotationEffect(isOrganizingMapJourneys ? .degrees(mapJourneyWiggle(for: record.id) * 1.45) : .zero)
            .offset(y: isOrganizingMapJourneys ? mapJourneyWiggle(for: record.id) * 0.9 : 0)
            .scaleEffect(isDropTarget ? 1.24 : 1)
            .opacity(isDragged ? 0.16 : 1)
            .animation(
                isOrganizingMapJourneys
                    ? .easeInOut(duration: 0.16)
                        .repeatForever(autoreverses: true)
                        .delay(mapJourneyWiggleDelay(for: record.id))
                    : .easeOut(duration: 0.16),
                value: isOrganizingMapJourneys
            )
            .animation(.spring(response: 0.24, dampingFraction: 0.7), value: journeyOrganizerHoveredTarget)
    }

    private func mapMarkerTargetFrame(for record: UserMapRecord) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: JourneyOrganizerTargetFramePreferenceKey.self,
                value: isOrganizingMapJourneys
                    ? [.record(record.id): proxy.frame(in: JourneyOrganizerCoordinateSpace.space)]
                    : [:]
            )
        }
    }

    private func mapJourneyWiggleDelay(for id: UUID) -> Double {
        Double(abs(id.uuidString.hashValue % 6)) * 0.018
    }

    /// Opens a memory in the already-mounted MyMap canvas. A list row no
    /// longer pushes a second map, so the user can naturally return to List
    /// and keep the same map context. We deliberately do not fly the camera:
    /// the compact capsule is the immediate acknowledgement and the person
    /// remains in control of looking around the map.
    private func openRecordFromList(_ record: UserMapRecord) {
        isSearchFocused = false
        hasPresentedMap = true
        listFocusRecordID = record.isMapExperienceItem ? record.id : nil

        withAnimation(.easeInOut(duration: 0.24)) {
            display = .map
        }

        DispatchQueue.main.async {
            if case let .journey(journey) = record.kind {
                enterMapJourney(
                    journey,
                    savesEntryRecord: true,
                    size: mapSize,
                    safeAreaBottom: mapSafeAreaBottom
                )
            } else {
                presentMapCapsule(record)
            }
        }
    }

    private var isListRecordFocusActive: Bool {
        display == .map && mapFocusedJourney == nil && listFocusRecordID != nil
    }

    private func returnToList() {
        let recordID = listFocusRecordID
        listFocusRecordID = nil
        listReturnRecordID = recordID
        mapSelectedRecord = nil
        mapCapsulePresentation.dismiss()

        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            display = .list
        }
    }

    private func restoreListPosition(using proxy: ScrollViewProxy) {
        guard let recordID = listReturnRecordID else { return }

        DispatchQueue.main.async {
            proxy.scrollTo(recordID, anchor: .center)
            listReturnRecordID = nil
        }
    }

    private var archiveControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    TextField("Search memories", text: $searchText)
                        .font(.subheadline)
                        .focused($isSearchFocused)
                        .submitLabel(.search)

                    if searchText.isEmpty == false {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    presentFilter(.all)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(hasActiveFilters ? Color.white : Color.primary)
                        .frame(width: 38, height: 38)
                        .background(hasActiveFilters ? Color.black : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filter records")
            }

            if hasActiveFilters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if showsAllTypes == false {
                            ArchiveActiveFilterToken(
                                title: typeFilterTitle,
                                onOpen: { presentFilter(.type) },
                                onClear: { clearFilter(.type) }
                            )
                        }

                        if filters.datePreset != .anyTime {
                            ArchiveActiveFilterToken(
                                title: dateFilterTitle,
                                onOpen: { presentFilter(.date) },
                                onClear: { clearFilter(.date) }
                            )
                        }

                        if filters.cities.isEmpty == false {
                            ArchiveActiveFilterToken(
                                title: cityFilterTitle,
                                onOpen: { presentFilter(.city) },
                                onClear: { clearFilter(.city) }
                            )
                        }

                        Button("Clear") {
                            clearFilter(.all)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .background(display == .map ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(.systemBackground)))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(display == .map ? Color.white.opacity(0.18) : Color(.separator).opacity(0.25))
                .frame(height: 1)
        }
    }

    private var mapJourneyIsActive: Bool {
        display == .map && mapFocusedJourney != nil
    }

    /// A Journey replaces the archive controls with the same folder chrome
    /// used by MapTalk. Its child row, map pins and capsule all read from one
    /// `MapJourneyScope`, so they cannot drift into the general archive.
    @ViewBuilder
    private var mapJourneyControls: some View {
        if let journey = mapFocusedJourney {
            let journeyScope = scope(for: journey)

            VStack(spacing: 6) {
                MapJourneyNavigationHeader(
                    path: mapJourneyStack + [journey],
                    selectedJourneyId: journey.id,
                    onSelect: { selectedJourney in
                        focusMapJourneyFromBreadcrumb(
                            selectedJourney,
                            size: mapSize,
                            safeAreaBottom: mapSafeAreaBottom
                        )
                    },
                    onExit: {
                        exitMapJourneyFocus(
                            size: mapSize,
                            safeAreaBottom: mapSafeAreaBottom
                        )
                    }
                )

                if journeyScope.storyItems.isEmpty == false {
                    RealStoriesRow(
                        items: journeyScope.storyItems,
                        selectedId: mapSelectedRecord?.id,
                        onSelectReal: { real in
                            guard let item = journeyScope.storyItem(for: real.id) else { return }
                            selectMapJourneyStory(item)
                        },
                        onSelectPOIGroup: { group in
                            guard let item = journeyScope.storyItem(for: group.id) else { return }
                            selectMapJourneyStory(item)
                        },
                        onSelectJourney: { _ in },
                        userProvider: userProvider,
                        alignTrigger: mapReelAlignTrigger,
                        displayMode: .content,
                        isUnseen: { _ in false }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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
        }
    }

    private var showsAllTypes: Bool {
        filters.types.count == RecordType.allCases.count
    }

    private var typeFilterTitle: String {
        if showsAllTypes { return "All types" }
        let selected = RecordType.allCases
            .filter(filters.types.contains)
            .map(\.rawValue)
        return selected.joined(separator: " + ")
    }

    private var cityFilterTitle: String {
        if filters.cities.isEmpty { return "Everywhere" }
        let selected = availableCities.filter(filters.cities.contains)
        guard let first = selected.first else { return "Places" }
        return selected.count == 1 ? first : "\(first) + \(selected.count - 1)"
    }

    private var dateFilterTitle: String {
        guard filters.datePreset == .custom else { return filters.datePreset.rawValue }
        let start = min(filters.customStartDate, filters.customEndDate)
        let end = max(filters.customStartDate, filters.customEndDate)
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return "\(start.formatted(format)) – \(end.formatted(format))"
    }

    private func presentFilter(_ presentation: FilterPresentation) {
        isSearchFocused = false
        filterDraft = filters
        filterPresentation = presentation
    }

    private func applyFilters(_ newFilters: FilterState) {
        filters = newFilters
        if display == .map, mapFocusedJourney == nil {
            focusMap(on: filteredRecords(using: newFilters))
        }
    }

    private func clearFilter(_ presentation: FilterPresentation) {
        var updated = filters
        let defaultFilters = FilterState()

        switch presentation {
        case .all:
            updated = defaultFilters
        case .type:
            updated.types = defaultFilters.types
        case .date:
            updated.datePreset = defaultFilters.datePreset
            updated.customStartDate = defaultFilters.customStartDate
            updated.customEndDate = defaultFilters.customEndDate
        case .city:
            updated.cities.removeAll()
        }

        applyFilters(updated)
    }

    private func selectOnMap(
        _ record: UserMapRecord,
        size: CGSize,
        safeAreaBottom: CGFloat
    ) {
        if case let .journey(journey) = record.kind {
            enterMapJourney(
                journey,
                savesEntryRecord: true,
                size: size,
                safeAreaBottom: safeAreaBottom
            )
            return
        }

        // Pin taps stay in this map. They replace the compact capsule without
        // automatically moving the camera, matching the main MapTalk map.
        presentMapCapsule(record)
    }

    private func presentMapCapsule(_ record: UserMapRecord) {
        mapSelectedRecord = record
        mapCapsulePresentation.presentNewContent()
    }

    private func enterMapJourney(
        _ journey: JourneyPost,
        savesEntryRecord: Bool,
        size: CGSize,
        safeAreaBottom: CGFloat
    ) {
        let isCurrentJourney = mapFocusedJourney?.id == journey.id

        if mapFocusedJourney == nil, savesEntryRecord, mapJourneyEntryRegion == nil {
            mapJourneyEntryRecord = mapSelectedRecord
            mapJourneyEntryRegion = currentMapRegion
        }
        if let parent = mapFocusedJourney, parent.id != journey.id {
            mapJourneyStack.append(parent)
        }

        mapFocusedJourney = journey
        focusMapJourneyCamera(journey, size: size, safeAreaBottom: safeAreaBottom)

        guard let firstChild = storyRecords(for: journey).first else {
            // A folder never becomes a fake pager card. Empty folders keep
            // their map/header state but have no bottom capsule to present.
            mapSelectedRecord = UserMapRecord(
                id: journey.id,
                timestamp: journey.createdAt,
                kind: .journey(journey)
            )
            mapCapsulePresentation.dismiss()
            return
        }

        if isCurrentJourney,
           mapCapsulePresentation.isPresented,
           mapCapsulePresentation.isExpanded {
            mapSelectedRecord = firstChild
        } else {
            presentMapCapsule(firstChild)
        }
        mapReelAlignTrigger &+= 1
    }

    private func focusMapJourneyFromBreadcrumb(
        _ journey: JourneyPost,
        size: CGSize,
        safeAreaBottom: CGFloat
    ) {
        if let index = mapJourneyStack.firstIndex(where: { $0.id == journey.id }) {
            mapJourneyStack = Array(mapJourneyStack.prefix(upTo: index))
        }
        mapFocusedJourney = journey
        focusMapJourneyCamera(journey, size: size, safeAreaBottom: safeAreaBottom)
        if let firstChild = storyRecords(for: journey).first {
            presentMapCapsule(firstChild)
        } else {
            mapCapsulePresentation.dismiss()
        }
        mapReelAlignTrigger &+= 1
    }

    private func exitMapJourneyFocus(size: CGSize, safeAreaBottom: CGFloat) {
        if let parent = mapJourneyStack.popLast() {
            mapFocusedJourney = parent
            focusMapJourneyCamera(parent, size: size, safeAreaBottom: safeAreaBottom)
            if let firstChild = storyRecords(for: parent).first {
                presentMapCapsule(firstChild)
            } else {
                mapCapsulePresentation.dismiss()
            }
            mapReelAlignTrigger &+= 1
            return
        }

        let entryRecord = mapJourneyEntryRecord
        let entryRegion = mapJourneyEntryRegion
        mapFocusedJourney = nil
        mapJourneyStack.removeAll()
        mapJourneyEntryRecord = nil
        mapJourneyEntryRegion = nil

        if let entryRecord {
            presentMapCapsule(entryRecord)
        } else {
            mapCapsulePresentation.dismiss()
        }

        // Folder navigation is a scope change, not a new map transition.
        // Restore exactly the camera the user had before entering it instead
        // of flying to the prior card's pin.
        if let entryRegion {
            mapFlightController.cancelActiveTransition()
            withAnimation(.easeInOut(duration: 0.3)) {
                cameraPosition = .region(entryRegion)
            }
            currentMapRegion = entryRegion
        }
        mapReelAlignTrigger &+= 1
    }

    private func focusMapJourneyCamera(
        _ journey: JourneyPost,
        size: CGSize,
        safeAreaBottom: CGFloat
    ) {
        guard let target = MapJourneyCamera.target(
            for: journey,
            size: size,
            safeAreaBottom: safeAreaBottom,
            compactFraction: Self.mapCapsuleCompactFraction
        ) else {
            return
        }

        mapFlightController.cancelActiveTransition()
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
        currentMapRegion = target.region
    }

    private func openAttachedJourney(_ journey: JourneyPost) {
        enterMapJourney(
            journey,
            savesEntryRecord: true,
            size: mapSize,
            safeAreaBottom: mapSafeAreaBottom
        )
    }

    private func privateJourney(for id: UUID) -> JourneyPost? {
        if mapFocusedJourney?.id == id {
            return mapFocusedJourney
        }
        if let pathJourney = mapJourneyStack.first(where: { $0.id == id }) {
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
        guard let journey = mapFocusedJourney else { return filteredRecords }
        return storyRecords(for: journey)
    }

    @ViewBuilder
    private var mapCapsule: some View {
        if mapSequenceItems.isEmpty {
            MapJourneyEmptyCapsule()
        } else {
            MapExperienceCapsule(
                pager: .init(items: mapSequenceItems),
                selection: mapSequenceSelection,
                isExpanded: mapCapsulePresentation.isExpanded,
                onCollapsedTap: mapCapsulePresentation.expand,
                journeyProvider: privateJourney(for:),
                userProvider: userProvider,
                onJourneyAvatarStackTap: openAttachedJourney
            )
        }
    }

    /// The map has the same browsing contract as MapTalk: Reel and POI are
    /// pageable memories; Journey is a folder route, never a pager card.
    private var mapCapsuleRecords: [UserMapRecord] {
        if let journey = mapFocusedJourney {
            return storyRecords(for: journey)
        }

        var candidates = mapRecords

        if let selected = mapSelectedRecord,
           candidates.contains(where: { $0.id == selected.id }) == false,
           selected.isMapExperienceItem {
            candidates.insert(selected, at: 0)
        }

        return candidates
    }

    private var mapSequenceItems: [ExperienceDetailView.SequencePager.Item] {
        if let journey = mapFocusedJourney {
            return scope(for: journey).sequenceItems
        }

        return mapCapsuleRecords.compactMap { record in
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

    private var mapSequenceSelection: Binding<UUID> {
        Binding(
            get: {
                if let selected = mapSelectedRecord,
                   mapSequenceItems.contains(where: { $0.id == selected.id }) {
                    return selected.id
                }
                return mapSequenceItems.first?.id ?? UUID()
            },
            set: { identifier in
                guard let record = mapCapsuleRecords.first(where: { $0.id == identifier }) else { return }
                selectFromMapCapsulePager(record)
            }
        )
    }

    private func selectFromMapCapsulePager(_ record: UserMapRecord) {
        mapSelectedRecord = record
        mapReelAlignTrigger &+= 1
        let targetRegion = storyRegion(for: record)

        if mapCapsulePresentation.isExpanded {
            // The large sheet covers the map now, but it may be collapsed at
            // any point. Keep its pending camera framed for the compact card
            // rather than letting the pin reappear behind the card later.
            let framedTarget = mapStoryViewport?.framed(targetRegion) ?? targetRegion
            currentMapRegion = framedTarget
            cameraPosition = .region(framedTarget)
            return
        }

        flyToMapStory(record)
    }

    private func selectMapJourneyStory(_ item: RealStoriesRow.StoryItem) {
        guard let record = record(for: item) else { return }
        presentMapCapsule(record)
        flyToMapStory(record)
        mapReelAlignTrigger &+= 1
    }

    private func flyToMapStory(_ record: UserMapRecord) {
        mapFlightController.handleRegionChange(
            currentRegion: currentMapRegion,
            targetRegion: storyRegion(for: record),
            cause: mapFlightCause(for: record),
            viewport: mapStoryViewport,
            cameraPosition: $cameraPosition
        ) { region in
            currentMapRegion = region
        }
    }

    /// A compact capsule is not merely an overlay: it removes the bottom
    /// portion of the map from the user's usable field of view. Frame map
    /// jumps against the remaining area so the selected marker sits above the
    /// card instead of at the geometric center of the whole screen.
    private var mapStoryViewport: MapCameraViewport? {
        guard mapSize.height > 1 else { return nil }

        let archiveChromeInset = 10.0 + 38.0 + 11.0 + (hasActiveFilters ? 40.0 : 0.0)
        let topInset = mapFocusedJourney == nil
            ? archiveChromeInset
            : MapJourneyCamera.journeyChromeInset
        let bottomInset = mapSize.height * Self.mapCapsuleCompactFraction + mapSafeAreaBottom

        return MapCameraViewport(
            size: mapSize,
            topInset: topInset,
            bottomInset: bottomInset
        )
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

    private func mapFlightCause(for record: UserMapRecord) -> RegionChangeCause {
        switch record.kind {
        case .poi: .poi
        case .reel: .real
        case .journey: .journey
        }
    }

    private func focusMap(on records: [UserMapRecord]) {
        guard let targetRegion = mapRegion(for: records) else { return }

        withAnimation(.easeInOut(duration: 0.3)) {
            cameraPosition = .region(targetRegion)
        }
    }

    private func mapRegion(for records: [UserMapRecord]) -> MKCoordinateRegion? {
        guard records.isEmpty == false else { return nil }

        let coordinates = records.map(\.coordinate)
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLatitude = latitudes.min(),
              let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(),
              let maxLongitude = longitudes.max() else { return nil }

        let latitudeDelta = min(max((maxLatitude - minLatitude) * 1.35, 0.045), 150)
        let longitudeDelta = min(max((maxLongitude - minLongitude) * 1.35, 0.045), 320)
        return MKCoordinateRegion(
            center: .init(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: .init(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    @ViewBuilder
    private func mapMarker(for record: UserMapRecord) -> some View {
        let isSelected = record.id == mapSelectedRecord?.id && (
            mapCapsulePresentation.isPresented || mapFocusedJourney != nil
        )

        switch record.kind {
        case let .poi(rated):
            UserMapMarker(category: rated.poi.category)
                .scaleEffect(isSelected ? 1.22 : 1)
                .shadow(color: isSelected ? Color.black.opacity(0.28) : .clear, radius: 7, y: 3)
        case let .reel(reel):
            RealMapThumbnail(
                real: reel,
                user: userProvider(reel.userId),
                size: isSelected ? 46 : 38,
                isSelected: isSelected
            )
        case .journey:
            ZStack {
                MemoryThumbnail(record: record, size: 42, cornerRadius: 12)
                Image(systemName: "folder.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white, lineWidth: 1.5)
                }
                .shadow(color: Color.black.opacity(0.24), radius: 5, y: 2)
        }
    }

    private static let mapCapsuleCompactFraction: CGFloat = 0.35
    private static let mapCapsuleCompactDetent = PresentationDetent.fraction(mapCapsuleCompactFraction)

    private var viewToggle: some View {
        Button {
            let nextDisplay: Display = display == .list ? .map : .list

            if nextDisplay == .list {
                // Do not leave a map-only capsule floating over the archive
                // after the person returns to List.
                listReturnRecordID = listFocusRecordID
                listFocusRecordID = nil
                mapCapsulePresentation.dismiss()
            }

            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                display = nextDisplay
            }

            // First arrival gives the user a useful overview. Every later
            // switch preserves the camera they manually explored.
            if nextDisplay == .map, hasPresentedMap == false {
                hasPresentedMap = true
                focusMap(on: filteredRecords)
            }
        } label: {
            Label(display == .list ? "Map" : "List", systemImage: display == .list ? "map" : "list.bullet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 17)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.88), in: Capsule())
                .shadow(color: Color.black.opacity(0.22), radius: 10, y: 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .allowsHitTesting(true)
        .accessibilityLabel(display == .list ? "Show map" : "Show list")
    }

    private func sectionTitle(for record: UserMapRecord) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(record.timestamp) { return "Today" }
        if calendar.isDate(record.timestamp, equalTo: .now, toGranularity: .weekOfYear) { return "This Week" }
        return record.timestamp.formatted(.dateTime.month(.wide).year())
    }
}

private struct MapJourneyDragPreview: View {
    let record: UserMapRecord
    let user: User?

    var body: some View {
        draggedMarker
            .scaleEffect(1.26)
            .rotationEffect(.degrees(-2))
            .shadow(color: Color.black.opacity(0.32), radius: 14, y: 9)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "plus")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(Color.black, in: Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .offset(x: 8, y: 8)
            }
    }

    @ViewBuilder
    private var draggedMarker: some View {
        switch record.kind {
        case let .poi(rated):
            UserMapMarker(category: rated.poi.category)
                .scaleEffect(2.35)
                .frame(width: 48, height: 48)

        case let .reel(reel):
            RealMapThumbnail(
                real: reel,
                user: user,
                size: 52,
                isSelected: true
            )

        case .journey:
            MemoryThumbnail(record: record, size: 52, cornerRadius: 15)
        }
    }
}

/// A Journey has no geographic coordinate, so move mode gives it a small
/// private-photo-folder treatment: the memories are the visual identity, not
/// another line of map UI chrome.
private struct MapJourneyFolderDockCover: View {
    let records: [UserMapRecord]
    let isDropTarget: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            coverBackground
            memoryMosaic
            dropTargetOverlay
        }
        .frame(width: size, height: size)
        .clipShape(coverShape)
        .overlay {
            coverShape
                .stroke(
                    isDropTarget ? Color.black : Color.black.opacity(0.12),
                    lineWidth: isDropTarget ? 2 : 1
                )
        }
    }

    private var coverShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
    }

    private var coverBackground: some View {
        coverShape.fill(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private var memoryMosaic: some View {
        if records.isEmpty {
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(Color.secondary)
        } else {
            ForEach(Array(records.prefix(4).enumerated()), id: \.element.id) { index, record in
                folderMemoryThumbnail(record, at: index)
            }
        }
    }

    private func folderMemoryThumbnail(
        _ record: UserMapRecord,
        at index: Int
    ) -> some View {
        MemoryThumbnail(
            record: record,
            size: size * 0.54,
            cornerRadius: size * 0.15,
            showsKindBadge: false
        )
        .offset(
            x: index.isMultiple(of: 2) ? -size * 0.15 : size * 0.15,
            y: index < 2 ? -size * 0.15 : size * 0.15
        )
    }

    @ViewBuilder
    private var dropTargetOverlay: some View {
        if isDropTarget {
            coverShape.fill(Color.black.opacity(0.52))

            Image(systemName: "plus")
                .font(.body.weight(.black))
                .foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(Color.white, in: Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.14), lineWidth: 1))
        }
    }
}

/// The only required follow-up to a map-created Folder. It deliberately keeps
/// the action lightweight: name it now, or keep the sensible default and
/// continue arranging the map.
@MainActor
private struct JourneyFolderNamingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let folder: JourneyFolder
    let onSave: (JourneyFolder) -> Void

    @State private var title = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Name your Journey")
                        .font(.title3.weight(.bold))

                    Text(folder.memberReferences.count == 1
                         ? "Private folder · 1 memory"
                         : "Private folder · \(folder.memberReferences.count) memories")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            TextField("Untitled Journey", text: $title)
                .font(.body.weight(.medium))
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($isTitleFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .accessibilityIdentifier("mymap.journey-name")
                .onSubmit(save)

            HStack(spacing: 12) {
                Button("Not now") {
                    dismiss()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color(.secondarySystemBackground), in: Capsule(style: .continuous))

                Button(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Keep default" : "Save name") {
                    save()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.black, in: Capsule(style: .continuous))
                .accessibilityIdentifier("mymap.save-journey-name")
            }
        }
        .padding(24)
        .task {
            isTitleFocused = true
        }
    }

    private func save() {
        var renamedFolder = folder
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        renamedFolder.title = cleanTitle.isEmpty ? folder.title : cleanTitle
        onSave(renamedFolder)
        dismiss()
    }
}

private enum UserMapCity {
    static func city(from locationLabel: String) -> String? {
        let city = String(locationLabel.split(separator: ",", maxSplits: 1).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return city.isEmpty ? nil : city
    }

    static func label(for coordinate: CLLocationCoordinate2D) -> String {
        let candidates: [(String, CLLocationCoordinate2D)] = [
            ("Xi'an", .init(latitude: 34.341, longitude: 108.939)),
            ("Hangzhou", .init(latitude: 30.274, longitude: 120.155)),
            ("Suzhou", .init(latitude: 31.298, longitude: 120.583)),
            ("Seattle", .init(latitude: 47.6062, longitude: -122.3321))
        ]
        let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let nearest = candidates.min(by: {
            current.distance(from: CLLocation(latitude: $0.1.latitude, longitude: $0.1.longitude))
                < current.distance(from: CLLocation(latitude: $1.1.latitude, longitude: $1.1.longitude))
        }) else { return "Unknown location" }
        return nearest.0
    }
}

private struct ArchiveActiveFilterToken: View {
    let title: String
    let onOpen: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                Text(title)
                    .lineLimit(1)
                    .padding(.leading, 11)
                    .padding(.trailing, 8)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color(.separator).opacity(0.45))
                .frame(width: 1, height: 14)

            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear \(title) filter")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.primary)
        .background(Color(.secondarySystemBackground), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color(.separator).opacity(0.25), lineWidth: 1)
        }
    }
}

private struct ArchiveFilterOption: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                }

                Text(title)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                isSelected ? Color.black : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(.separator).opacity(isSelected ? 0 : 0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ArchiveDateHeader: View {
    let title: String
    let count: Int
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(seasonTint)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text(count.formatted())
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private var seasonTint: Color {
        switch Calendar.current.component(.month, from: date) {
        case 3...5:
            Color(red: 0.87, green: 0.66, blue: 0.70)
        case 6...8:
            Color(red: 0.54, green: 0.72, blue: 0.83)
        case 9...11:
            Color(red: 0.74, green: 0.58, blue: 0.39)
        default:
            Color(red: 0.58, green: 0.65, blue: 0.72)
        }
    }
}

private struct UserMapFilterSheet: View {
    let presentation: UserMapHomeView.FilterPresentation
    let cities: [String]
    @Binding var filters: UserMapHomeView.FilterState
    let resultCount: Int
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var citySearchText = ""

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    if showsType {
                        typeSection
                    }

                    if showsDate {
                        dateSection
                    }

                    if showsCity {
                        citySection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 92)
            }
            .background(Color(.systemBackground))
            .navigationTitle(presentation.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    onApply()
                    dismiss()
                } label: {
                    Text("Show \(resultCount) \(resultCount == 1 ? "memory" : "memories")")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { clearCurrentFacet() }
                        .disabled(canClearCurrentFacet == false)
                }
            }
        }
    }

    private var showsType: Bool {
        presentation == .all || presentation == .type
    }

    private var showsDate: Bool {
        presentation == .all || presentation == .date
    }

    private var showsCity: Bool {
        presentation == .all || presentation == .city
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("What you saved", detail: "Choose one or more kinds of memories.")

            ArchiveFilterOption(
                title: "All types",
                systemImage: "square.grid.2x2",
                isSelected: isShowingAllTypes,
                action: selectAllTypes
            )

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                spacing: 8
            ) {
                ForEach(UserMapHomeView.RecordType.allCases) { type in
                    ArchiveFilterOption(
                        title: type.rawValue,
                        systemImage: type.icon,
                        isSelected: filters.types.contains(type) && isShowingAllTypes == false,
                        action: { toggle(type) }
                    )
                }
            }
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("When it happened", detail: "Use a quick window or choose exact dates.")

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(UserMapHomeView.DatePreset.allCases.filter { $0 != .custom }) { preset in
                    ArchiveFilterOption(
                        title: preset.rawValue,
                        systemImage: dateIcon(for: preset),
                        isSelected: filters.datePreset == preset,
                        action: { filters.datePreset = preset }
                    )
                }
            }

            ArchiveFilterOption(
                title: "Choose dates",
                systemImage: "calendar",
                isSelected: filters.datePreset == .custom,
                action: { filters.datePreset = .custom }
            )

            if filters.datePreset == .custom {
                VStack(spacing: 0) {
                    DatePicker("From", selection: $filters.customStartDate, displayedComponents: .date)
                        .padding(.vertical, 12)
                    Divider()
                    DatePicker("To", selection: $filters.customEndDate, displayedComponents: .date)
                        .padding(.vertical, 12)
                }
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var citySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Places", detail: citySelectionDetail)

            ArchiveFilterOption(
                title: "Everywhere",
                systemImage: "globe",
                isSelected: filters.cities.isEmpty,
                action: { filters.cities.removeAll() }
            )

            if cities.count > 6 {
                citySearchField
            }

            if cities.isEmpty {
                Text("No saved places yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else if visibleCities.isEmpty {
                Text("No cities match \"\(citySearchText)\".")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleCities.enumerated()), id: \.element) { index, city in
                        Button {
                            toggle(city)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(city)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if filters.cities.contains(city) {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .padding(.horizontal, 13)
                            .frame(height: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < visibleCities.count - 1 {
                            Divider()
                                .padding(.leading, 39)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var citySearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Search cities", text: $citySearchText)
                .font(.subheadline)
            if citySearchText.isEmpty == false {
                Button {
                    citySearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isShowingAllTypes: Bool {
        filters.types.count == UserMapHomeView.RecordType.allCases.count
    }

    private var citySelectionDetail: String {
        guard filters.cities.isEmpty == false else {
            return "Select one city or combine a few."
        }
        return "\(filters.cities.count) \(filters.cities.count == 1 ? "city" : "cities") selected."
    }

    private var visibleCities: [String] {
        let matching = cities.filter { city in
            citySearchText.isEmpty || city.localizedCaseInsensitiveContains(citySearchText)
        }
        let selected = matching.filter(filters.cities.contains)
        let unselected = matching.filter { filters.cities.contains($0) == false }
        return selected + unselected
    }

    private var canClearCurrentFacet: Bool {
        switch presentation {
        case .all:
            return filters.isDefault == false
        case .type:
            return isShowingAllTypes == false
        case .date:
            return filters.datePreset != .anyTime
        case .city:
            return filters.cities.isEmpty == false
        }
    }

    private func selectAllTypes() {
        filters.types = Set(UserMapHomeView.RecordType.allCases)
    }

    private func toggle(_ type: UserMapHomeView.RecordType) {
        let allTypes = Set(UserMapHomeView.RecordType.allCases)

        if isShowingAllTypes {
            filters.types = [type]
        } else if filters.types.contains(type) {
            filters.types.remove(type)
            if filters.types.isEmpty {
                filters.types = allTypes
            }
        } else {
            filters.types.insert(type)
            if filters.types.count == allTypes.count {
                filters.types = allTypes
            }
        }
    }

    private func toggle(_ city: String) {
        if filters.cities.contains(city) {
            filters.cities.remove(city)
        } else {
            filters.cities.insert(city)
        }
    }

    private func clearCurrentFacet() {
        let defaultFilters = UserMapHomeView.FilterState()

        switch presentation {
        case .all:
            filters = defaultFilters
        case .type:
            filters.types = defaultFilters.types
        case .date:
            filters.datePreset = defaultFilters.datePreset
            filters.customStartDate = defaultFilters.customStartDate
            filters.customEndDate = defaultFilters.customEndDate
        case .city:
            filters.cities.removeAll()
        }
    }

    private func dateIcon(for preset: UserMapHomeView.DatePreset) -> String? {
        switch preset {
        case .anyTime: "infinity"
        case .today: "sun.max"
        case .week: "calendar"
        case .month: "calendar.badge.clock"
        case .year: "calendar.badge.exclamationmark"
        case .custom: nil
        }
    }
}

private struct UserMapRecordCard: View {
    let record: UserMapRecord

    var body: some View {
        HStack(spacing: 12) {
            MemoryThumbnail(record: record, size: 64, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(record.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var metadata: String {
        switch record.kind {
        case let .poi(rated):
            return "POI · \(rated.poi.category.displayName) · \(record.cityName)"
        case .reel:
            return "Reel · \(record.cityName)"
        case let .journey(journey):
            return "Journey · \(journey.reels.count + journey.pois.count) memories"
        }
    }
}

struct MemoryThumbnail: View {
    let record: UserMapRecord
    let size: CGFloat
    let cornerRadius: CGFloat
    let showsKindBadge: Bool

    init(
        record: UserMapRecord,
        size: CGFloat,
        cornerRadius: CGFloat,
        showsKindBadge: Bool = true
    ) {
        self.record = record
        self.size = size
        self.cornerRadius = cornerRadius
        self.showsKindBadge = showsKindBadge
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnailContent
            if showsKindBadge, case .journey = record.kind {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: max(size * 0.16, 8), weight: .bold))
                    .foregroundStyle(.white)
                    .padding(max(size * 0.09, 4))
                    .background(Color.black.opacity(0.55), in: Circle())
                    .padding(max(size * 0.07, 3))
            }
            if showsKindBadge, case .reel = record.kind {
                Image(systemName: "play.fill")
                    .font(.system(size: max(size * 0.15, 8), weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(max(size * 0.1, 5))
                    .background(Color.black.opacity(0.48), in: Circle())
                    .padding(max(size * 0.07, 3))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        switch record.kind {
        case let .poi(rated):
            if let url = poiPreviewURL(for: rated) {
                MemoryRemoteImage(url: url)
            } else {
                Image(systemName: rated.poi.category.symbolName)
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: rated.poi.category.markerGradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        case let .reel(reel):
            if let url = reelPreviewURL(for: reel) {
                MemoryRemoteImage(url: url)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        case let .journey(journey):
            JourneyMemoryThumbnail(journey: journey, size: size)
        }
    }

    private func poiPreviewURL(for rated: RatedPOI) -> URL? {
        rated.media.compactMap { media in
            switch media.kind {
            case let .photo(url): return url
            case let .video(_, poster): return poster
            }
        }.first ?? rated.checkIns.flatMap(\.media).compactMap { media in
            switch media.kind {
            case let .photo(url): return url
            case let .video(_, poster): return poster
            }
        }.first
    }

    private func reelPreviewURL(for reel: RealPost) -> URL? {
        reel.attachments.compactMap { attachment in
            switch attachment.kind {
            case let .photo(url): return url
            case let .video(_, poster): return poster
            case .emoji: return nil
            }
        }.first
    }
}

private struct MemoryRemoteImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFill()
            case .empty:
                Color(.tertiarySystemFill)
                    .overlay { ProgressView().controlSize(.mini) }
            default:
                Color(.tertiarySystemFill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

struct JourneyMemoryThumbnail: View {
    let journey: JourneyPost
    let size: CGFloat

    var body: some View {
        if imageURLs.isEmpty {
            Image(systemName: "map")
                .font(.system(size: size * 0.3, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else if imageURLs.count == 1, let imageURL = imageURLs.first {
            MemoryRemoteImage(url: imageURL)
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)],
                spacing: 1
            ) {
                ForEach(0..<4, id: \.self) { index in
                    if let imageURL = imageURLs[safe: index] {
                        MemoryRemoteImage(url: imageURL)
                    } else {
                        Color(.tertiarySystemFill)
                    }
                }
            }
        }
    }

    private var imageURLs: [URL] {
        let reelURLs = journey.reels.flatMap { reel in
            reel.attachments.compactMap { attachment -> URL? in
                switch attachment.kind {
                case let .photo(url): return url
                case let .video(_, poster): return poster
                case .emoji: return nil
                }
            }
        }
        let poiURLs = journey.pois.flatMap { rated in
            rated.media.compactMap { media -> URL? in
                switch media.kind {
                case let .photo(url): return url
                case let .video(_, poster): return poster
                }
            }
        }
        return Array((reelURLs + poiURLs).prefix(4))
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
