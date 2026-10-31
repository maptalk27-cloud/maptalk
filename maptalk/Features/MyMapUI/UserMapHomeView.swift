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

    func publicationStatus(in pending: [UUID: PendingPublicationStatus]) -> PendingPublicationStatus? {
        pendingPublication(in: pending)?.status
    }

    func pendingPublication(in pending: [UUID: PendingPublicationStatus]) -> (id: UUID, status: PendingPublicationStatus)? {
        let ids: [UUID]
        switch kind {
        case let .reel(reel): ids = [reel.id]
        case let .poi(rated): ids = rated.checkIns.map(\.id)
        case .journey: ids = []
        }
        let entries = ids.compactMap { id in pending[id].map { (id: id, status: $0) } }
        // A grouped place must still expose a failed visit even when another
        // visit is uploading successfully.
        return entries.first { if case .failed = $0.status { return true }; return false }
            ?? entries.first { $0.status == .uploading || $0.status == .processing }
            ?? entries.first
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
            UserMapRecord(id: $0.id, timestamp: $0.activityDate, kind: .reel($0))
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

/// Keep browsing and organizing as two distinct intents. A nearby marker can
/// preview as a destination only after a real drag, and release is accepted
/// only after that destination has stayed stable for a short beat.
private enum JourneyOrganizerInteraction {
    /// Once the organizer is already visible, picking a memory up should feel
    /// nearly immediate. It is still a hold (so an ordinary map pan remains
    /// available), but it should not make the person wait twice.
    static let pickupDelayWhileOrganizing: TimeInterval = 0.12
    static let minimumDragDistance: CGFloat = 18
    /// A receiver becomes real almost as soon as it is visually open. A long
    /// delay here made a clearly intentional, quick drop silently return.
    static let targetArmDelay: TimeInterval = 0.11
    static let targetAcquisitionPadding: CGFloat = 8
    static let targetRetentionPadding: CGFloat = 16
    static let targetCommitPadding: CGFloat = targetAcquisitionPadding
}

/// The organizer uses one cover geometry everywhere: the rail, its open
/// pocket, and the token that lands in it. Keeping this in one place avoids a
/// visible jump between the drag overlay and the Folder itself.
private enum JourneyFolderCoverLayout {
    static let size: CGFloat = 64
    static let thumbnailSize: CGFloat = size * 0.54
    static let dragTokenSize: CGFloat = 52
    static let dragTokenLiftScale: CGFloat = 1.06
    /// The lifted token shrinks into a thumbnail without changing its visual
    /// footprint at the instant the Folder takes ownership of it.
    static let landingTokenScale = thumbnailSize / (dragTokenSize * dragTokenLiftScale)

    static func slotOffset(for index: Int) -> CGSize {
        CGSize(
            width: index.isMultiple(of: 2) ? -size * 0.15 : size * 0.15,
            height: index < 2 ? -size * 0.15 : size * 0.15
        )
    }

    static func slotCenter(in cover: CGRect, at index: Int) -> CGPoint {
        let offset = slotOffset(for: index)
        return CGPoint(x: cover.midX + offset.width, y: cover.midY + offset.height)
    }
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

/// The folder cover is deliberately measured separately from its title. A
/// completed merge should land in the photos, not in the label beneath them.
private struct JourneyFolderCoverFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// The glass rail is one private surface, not merely the union of its tiles.
/// Publishing its real frame prevents a map marker behind a gap or side
/// padding from becoming an invisible drop target.
private struct JourneyOrganizerDockFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.isEmpty == false {
            value = next
        }
    }
}

@MainActor
private struct JourneyOrganizerDrag {
    let record: UserMapRecord
    let reference: JourneyFolder.MemberReference
    let startLocation: CGPoint
    var location: CGPoint
}

@MainActor
private struct JourneyOrganizerDrop: Identifiable {
    let id = UUID()
    let drag: JourneyOrganizerDrag
    let target: JourneyOrganizerTarget
    /// The exact visual token position on release, including the gentle
    /// magnetic pull. It prevents a one-frame snap back to the raw finger
    /// location after the hover target clears.
    let releaseLocation: CGPoint
    /// Frozen in the organizer coordinate space on release. It must not move
    /// with a layout update while the token is on its way to the destination.
    let landingLocation: CGPoint
}

private struct JourneyOrganizerReturn: Identifiable {
    let id = UUID()
    let drag: JourneyOrganizerDrag
    /// The rendered token position when the gesture was cancelled. This is
    /// distinct from the touch point because the token rides just above the
    /// finger and may be lightly magnetized to a target.
    let launchLocation: CGPoint
    let launchScale: CGFloat
    let homeLocation: CGPoint
}

/// Nearby map memories stay visually at their real coordinate. When their
/// icons overlap, one hit surface represents the stack and taps cycle through
/// its contents instead of moving the map objects apart.
private struct MapMemoryHitCluster: Identifiable {
    let records: [UserMapRecord]
    let point: CGPoint

    var id: String {
        records.map { $0.id.uuidString }.joined(separator: ":")
    }

    var defaultRecord: UserMapRecord {
        // This is the record that is visually on top when MapKit renders the
        // annotations in their existing order, so a first interaction still
        // feels like touching the visible marker.
        records.last!
    }
}

/// A fresh Folder is created by a physical map gesture first, then receives
/// its human name without interrupting that spatial action.
private struct JourneyFolderRenameRequest: Identifiable {
    let folder: JourneyFolder

    var id: UUID { folder.id }
}

/// A Folder does not remove its memories from the map; it only gathers their
/// references. This short-lived state carries the new container from its
/// on-map receiver to the private shelf before naming begins.
private struct JourneyFolderMergeAnimation: Identifiable {
    let id = UUID()
    let folder: JourneyFolder
    let sourceRecord: UserMapRecord
    let targetRecord: UserMapRecord
    /// The receiver centre at the instant the memory becomes a Folder.
    /// Keeping it immutable avoids a flight path that follows MapKit layout.
    let origin: CGPoint
    /// Captured when the new rail tile has completed layout. The container
    /// never retargets mid-flight if the shelf later receives another layout
    /// pass.
    var shelfDestination: CGPoint? = nil
}

private struct JourneyFolderAppendAnimation: Identifiable {
    let id = UUID()
    let folderID: UUID
    let sourceRecord: UserMapRecord
    let previousRecords: [UserMapRecord]
}

/// The same choreography as putting an app into an iPhone folder: a receiver
/// appears, the item tucks into one of its slots, then the completed container
/// is put away on the private Journey shelf.
private enum JourneyFolderMergePhase: Equatable {
    case receiving
    case traveling
    case settled
}

private enum JourneyFolderAppendPhase: Equatable {
    case receiving
    case settled
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
        recognizer.minimumPressDuration = isOrganizing
            ? JourneyOrganizerInteraction.pickupDelayWhileOrganizing
            : 0.55
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
        // In organize mode a marker is a physical object. A brief touch is
        // intentionally inert; outside that mode, a short touch stays a tap
        // and a moving touch can still pan the map.
        recognizer.minimumPressDuration = isOrganizing
            ? JourneyOrganizerInteraction.pickupDelayWhileOrganizing
            : 0.55
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

@MainActor
private struct MyMapRemovalConfirmation: ViewModifier {
    @Binding var record: UserMapRecord?
    let deletesPublishedPosts: Bool
    let onRemove: (JourneyFolder.MemberReference) -> Void

    func body(content: Content) -> some View {
        let isPresented = Binding(
            get: { record != nil },
            set: { isShowing in
                if isShowing == false {
                    record = nil
                }
            }
        )

        content.confirmationDialog(
            deletesPublishedPosts ? "Delete this memory?" : "Remove from MyMap?",
            isPresented: isPresented,
            titleVisibility: .visible,
            presenting: record
        ) { selectedRecord in
            Button(deletesPublishedPosts ? "Delete" : "Remove", role: .destructive) {
                guard let reference = selectedRecord.journeyMemberReference else { return }
                onRemove(reference)
                record = nil
            }
        } message: { selectedRecord in
            if deletesPublishedPosts {
                if case .poi = selectedRecord.kind {
                    Text("Delete your visits to this place from MyMap and the feed. Other people's visits won't change.")
                } else {
                    Text("Delete this post from MyMap and the feed. This can't be undone.")
                }
            } else {
                Text("This only removes the memory from your private MyMap.")
            }
        }
    }
}

/// Preserve Button accessibility/disabled semantics, but require a real tap.
/// A plain List Button can otherwise activate on an unsupported-direction swipe.
private struct ArchiveRecordButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .onTapGesture {
                if isEnabled { configuration.trigger() }
            }
            .accessibilityAction {
                if isEnabled { configuration.trigger() }
            }
    }
}

struct UserMapHomeView: View {
    private enum Display: Equatable { case list, map }

    /// One selection mode, entered from MyMap or from a specific collection.
    /// Search and filtering stay in their familiar home rather than becoming
    /// part of Collection management.
    private struct CollectionMemorySelectionContext: Identifiable {
        let id = UUID()
        let destinationFolderID: UUID?
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
    /// Private collection catalog. It can resolve an in-map collection scope
    /// without making collections part of the MyMap root stream.
    let journeyProvider: (UUID) -> JourneyPost?
    /// Local-only collections. These are deliberately separate from the
    /// chronological POI / Reel records above.
    let journeyFolders: [JourneyFolder]
    let reels: [RealPost]
    let footprints: [UserMapViewModel.Footprint]
    let canEditJourneyFolders: Bool
    let deletesPublishedPosts: Bool
    let pendingPublications: [UUID: PendingPublicationStatus]
    let onRetryPublication: (UUID) -> Void
    let onCreateJourneyFolder: (String, [JourneyFolder.MemberReference]) -> JourneyFolder?
    let onSaveJourneyFolder: (JourneyFolder) -> Void
    let onDeleteJourneyFolder: (UUID) -> Void
    let onRemoveFromMyMap: (JourneyFolder.MemberReference) -> Void
    let onMapUserNavigation: () -> Void
    let userProvider: (UUID) -> User?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var display: Display = .list
    /// The map stays mounted beneath the archive, but its first presentation
    /// should still frame the available memories. Later List ↔ Map switches
    /// preserve the person's manually chosen viewport.
    @State private var hasPresentedMap = false
    @State private var hasUserNavigatedMap = false
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
    @State private var isCollectionPickerPresented = false
    @State private var collectionMemorySelection: CollectionMemorySelectionContext?
    @State private var selectedCollectionMemoryReferences: Set<JourneyFolder.MemberReference> = []
    @State private var journeyFolderRenameRequest: JourneyFolderRenameRequest?
    @State private var isJourneyCollectionsPresented = false
    @State private var activeCollection: JourneyFolder?
    @State private var recordPendingRemoval: UserMapRecord?
    @State private var journeyOrganizerRenamePendingFolder: JourneyFolder?
    @State private var isOrganizingMapJourneys = false
    @State private var journeyOrganizerDrag: JourneyOrganizerDrag?
    @State private var journeyOrganizerDrop: JourneyOrganizerDrop?
    @State private var journeyOrganizerReturn: JourneyOrganizerReturn?
    @State private var isJourneyOrganizerDragLifted = false
    @State private var isJourneyOrganizerDropSettling = false
    @State private var isJourneyOrganizerReturning = false
    @State private var journeyOrganizerSourceInFlightID: UUID?
    /// A quiet selection inside an overlapping stack. It lets a person choose
    /// which stacked memory to pick up without opening a browsing card.
    @State private var journeyOrganizerSelectedRecordID: UUID?
    @State private var journeyOrganizerCompletedTarget: JourneyOrganizerTarget?
    @State private var journeyOrganizerHoveredTarget: JourneyOrganizerTarget?
    @State private var journeyOrganizerArmedTarget: JourneyOrganizerTarget?
    @State private var journeyOrganizerHoverRevision = 0
    @State private var journeyOrganizerTargetFrames: [JourneyOrganizerTarget: CGRect] = [:]
    @State private var journeyFolderCoverFrames: [UUID: CGRect] = [:]
    @State private var journeyOrganizerDockFrame: CGRect = .zero
    @State private var journeyOrganizerDockScrollRequestID: UUID?
    @State private var journeyFolderMergeAnimation: JourneyFolderMergeAnimation?
    @State private var journeyFolderMergePhase: JourneyFolderMergePhase?
    @State private var journeyFolderAppendAnimation: JourneyFolderAppendAnimation?
    @State private var journeyFolderAppendPhase: JourneyFolderAppendPhase?
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
        deletesPublishedPosts: Bool = false,
        pendingPublications: [UUID: PendingPublicationStatus] = [:],
        onRetryPublication: @escaping (UUID) -> Void = { _ in },
        onCreateJourneyFolder: @escaping (String, [JourneyFolder.MemberReference]) -> JourneyFolder? = { _, _ in nil },
        onSaveJourneyFolder: @escaping (JourneyFolder) -> Void = { _ in },
        onDeleteJourneyFolder: @escaping (UUID) -> Void = { _ in },
        onRemoveFromMyMap: @escaping (JourneyFolder.MemberReference) -> Void = { _ in },
        onMapUserNavigation: @escaping () -> Void = {},
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
        self.deletesPublishedPosts = deletesPublishedPosts
        self.pendingPublications = pendingPublications
        self.onRetryPublication = onRetryPublication
        self.onCreateJourneyFolder = onCreateJourneyFolder
        self.onSaveJourneyFolder = onSaveJourneyFolder
        self.onDeleteJourneyFolder = onDeleteJourneyFolder
        self.onRemoveFromMyMap = onRemoveFromMyMap
        self.onMapUserNavigation = onMapUserNavigation
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
        .overlay(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                if display == .map {
                    mapJourneyDock
                        .padding(.horizontal, 16)
                        .padding(.bottom, 52)
                        .opacity(isOrganizingMapJourneys ? 1 : 0)
                        // The shelf may scroll while idle, but its geometry
                        // must stay still from release until the token has
                        // landed. Otherwise a correct drop can appear to
                        // slide away underneath the travelling memory.
                        .allowsHitTesting(
                            isOrganizingMapJourneys
                                && isJourneyOrganizerTransactionActive == false
                        )
                        .accessibilityHidden(isOrganizingMapJourneys == false)
                }

                if isSelectingCollectionMemories {
                    collectionSelectionAction
                        .zIndex(100)
                }

                if mapJourneyIsActive == false,
                   isSelectingCollectionMemories == false,
                   isListRecordFocusActive == false {
                    viewToggle
                        // Keep the List/Map control above the scroll view's
                        // NavigationLinks; otherwise its visual capsule can be
                        // tapped through into an archive row.
                        .zIndex(100)
                        .opacity(isOrganizingMapJourneys ? 0 : 1)
                        .offset(y: isOrganizingMapJourneys ? 72 : 0)
                        .allowsHitTesting(isOrganizingMapJourneys == false)
                }
            }
            // The chrome lives in a fixed overlay. Entering organize mode no
            // longer changes the map canvas beneath a held marker.
            .padding(.bottom, 18)
            .animation(organizerChromeAnimation, value: isOrganizingMapJourneys)
        }
        .overlay {
            GeometryReader { proxy in
                if let merge = journeyFolderMergeAnimation,
                   let phase = journeyFolderMergePhase {
                    mapJourneyFolderMergeAnimation(
                        merge,
                        phase: phase,
                        in: proxy
                    )
                }

                if let drag = journeyOrganizerDrag {
                    liftedMapMarkerPreview(for: drag.record)
                    .position(mapJourneyDragPreviewPosition(for: drag, in: proxy))
                    .scaleEffect(isJourneyOrganizerDragLifted ? 1 : 0.82)
                    .opacity(isJourneyOrganizerDragLifted ? 1 : 0.01)
                    .transition(.opacity)
                    .animation(organizerLiftAnimation, value: isJourneyOrganizerDragLifted)
                } else if let returning = journeyOrganizerReturn {
                    liftedMapMarkerPreview(for: returning.drag.record)
                        .position(mapJourneyReturnPosition(for: returning, in: proxy))
                        .scaleEffect(isJourneyOrganizerReturning ? 0.72 : returning.launchScale)
                        .opacity(isJourneyOrganizerReturning ? 0.02 : 1)
                        .transition(.opacity)
                        .animation(organizerLandingAnimation, value: isJourneyOrganizerReturning)
                } else if let drop = journeyOrganizerDrop {
                    MapJourneyFolderTokenPreview(record: drop.drag.record)
                    .position(mapJourneyDropPosition(for: drop, in: proxy))
                    .scaleEffect(
                        isJourneyOrganizerDropSettling
                            ? JourneyFolderCoverLayout.landingTokenScale
                            : 1
                    )
                    .transition(.opacity)
                    .animation(organizerLandingAnimation, value: isJourneyOrganizerDropSettling)
                }
            }
            .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // List owns its archive controls below. Attaching them directly to
            // the List gives its pinned section headers the same safe-area
            // geometry, instead of letting the first row slide behind chrome
            // owned by this parent ZStack.
            if display == .map {
                if mapFocusedJourney != nil {
                    mapJourneyControls
                } else if isListRecordFocusActive == false {
                    archiveControls
                        .opacity(isOrganizingMapJourneys ? 0 : 1)
                        .offset(y: isOrganizingMapJourneys ? -16 : 0)
                        .allowsHitTesting(isOrganizingMapJourneys == false)
                        .accessibilityHidden(isOrganizingMapJourneys)
                        .animation(organizerChromeAnimation, value: isOrganizingMapJourneys)
                }
            }
        }
        .navigationTitle(collectionSelectionNavigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        // A root Map is still MyMap. Only a focused Journey replaces this
        // identity with its own breadcrumb header.
        .toolbar(mapJourneyIsActive ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if isSelectingCollectionMemories {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: cancelCollectionMemorySelection)
                        .accessibilityIdentifier("mymap.cancel-selection")
                }
            } else if isListRecordFocusActive {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: returnToList) {
                        Label("List", systemImage: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("Return to list")
                }
            }

            if isSelectingCollectionMemories == false,
               display == .list,
               canEditJourneyFolders {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Select") {
                        beginCollectionMemorySelection()
                    }
                    .disabled(records.isEmpty)
                    .accessibilityIdentifier("mymap.select-memories")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentCollectionsDirectory()
                    } label: {
                        Image(systemName: "folder")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collections")
                    .accessibilityIdentifier("mymap.collections-entry")
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
                    .disabled(isJourneyOrganizerTransactionActive)
                    .opacity(isJourneyOrganizerTransactionActive ? 0.45 : 1)
                }
            }
        }
        .modifier(
            MyMapRemovalConfirmation(
                record: $recordPendingRemoval,
                deletesPublishedPosts: deletesPublishedPosts,
                onRemove: onRemoveFromMyMap
            )
        )
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
        .sheet(isPresented: $isCollectionPickerPresented) {
            JourneyFolderPickerSheet(
                folders: journeyFolders,
                references: selectedCollectionReferencesInListOrder,
                onSelect: { folderID in
                    guard append(selectedCollectionReferencesInListOrder, toJourneyFolder: folderID) != nil else { return }
                    finishCollectionMemorySelection()
                },
                onCreate: { title in
                    let references = selectedCollectionReferencesInListOrder
                    guard references.isEmpty == false,
                          onCreateJourneyFolder(title, references) != nil else { return }
                    finishCollectionMemorySelection()
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isJourneyCollectionsPresented) {
            JourneyCollectionsSheet(
                folders: journeyFolders,
                reels: reels,
                footprints: footprints,
                selectedFolder: $activeCollection,
                onCreate: { title in
                    onCreateJourneyFolder(title, [])
                },
                onAddMemories: { folder in
                    isJourneyCollectionsPresented = false
                    beginCollectionMemorySelection(for: folder.id)
                },
                onOpenMemory: { record in
                    isJourneyCollectionsPresented = false
                    activeCollection = nil
                    DispatchQueue.main.async {
                        openRecordFromList(record)
                    }
                },
                onSave: onSaveJourneyFolder,
                onDelete: onDeleteJourneyFolder
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $journeyFolderRenameRequest) { request in
            JourneyFolderNamingSheet(
                folder: request.folder,
                onSave: onSaveJourneyFolder,
                onCancel: cancelMapJourneyFolderCreation
            )
            .presentationDetents([.height(264)])
            .presentationDragIndicator(.visible)
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
        .onPreferenceChange(JourneyFolderCoverFramePreferenceKey.self) { frames in
            journeyFolderCoverFrames = frames
            schedulePendingMapJourneyFolderMergeIfReady()
        }
        .onPreferenceChange(JourneyOrganizerDockFramePreferenceKey.self) { frame in
            journeyOrganizerDockFrame = frame
        }
        .onChangeCompat(of: [
            region.center.latitude, region.center.longitude,
            region.span.latitudeDelta, region.span.longitudeDelta
        ]) { _ in
            // The canvas stays mounted while List covers it. Forward a late
            // startup fix to an empty map without resetting journal browsing.
            guard records.isEmpty,
                  hasUserNavigatedMap == false,
                  cameraPosition.positionedByUser == false else { return }
            cameraPosition = .region(region)
            currentMapRegion = region
        }
        .onChangeCompat(of: cameraPosition.positionedByUser) { positionedByUser in
            guard positionedByUser else { return }
            hasUserNavigatedMap = true
            onMapUserNavigation()
        }
        .onChange(of: records.compactMap(\.journeyMemberReference)) { _, references in
            // Refresh and pending-upload reconciliation can replace records.
            // Never keep a count for memories that can no longer be added.
            selectedCollectionMemoryReferences.formIntersection(references)
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

    private var isSelectingCollectionMemories: Bool {
        collectionMemorySelection != nil
    }

    private var collectionSelectionNavigationTitle: String {
        if let target = collectionSelectionTarget {
            return "Add to \(target.title)"
        }
        return isSelectingCollectionMemories ? "Select memories" : "MyMap"
    }

    private var collectionSelectionTarget: JourneyFolder? {
        guard let folderID = collectionMemorySelection?.destinationFolderID else { return nil }
        return journeyFolders.first(where: { $0.id == folderID })
    }

    private var selectedCollectionReferencesInListOrder: [JourneyFolder.MemberReference] {
        records.compactMap(\.journeyMemberReference)
            .filter(selectedCollectionMemoryReferences.contains)
            .filter { collectionSelectionTarget?.memberReferences.contains($0) != true }
    }

    private var collectionSelectionAction: some View {
        let count = selectedCollectionReferencesInListOrder.count
        let title = collectionMemorySelection?.destinationFolderID == nil ? "Add to collection" : "Add memories"
        return Button(action: completeCollectionMemorySelection) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.16), in: Capsule())
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 17)
            .padding(.vertical, 12)
            .background(count == 0 ? Color(.systemGray3) : Color.black.opacity(0.88), in: Capsule())
            .shadow(color: .black.opacity(count == 0 ? 0 : 0.18), radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityLabel(title)
        .accessibilityValue("\(count) selected")
        .accessibilityIdentifier("mymap.add-selected-memories")
    }

    private func beginCollectionMemorySelection(for folderID: UUID? = nil) {
        guard canEditJourneyFolders else { return }
        isSearchFocused = false
        listFocusRecordID = nil
        listReturnRecordID = nil
        mapSelectedRecord = nil
        mapCapsulePresentation.dismiss()
        selectedCollectionMemoryReferences.removeAll()
        collectionMemorySelection = CollectionMemorySelectionContext(
            destinationFolderID: folderID
        )
        withAnimation(.easeInOut(duration: 0.2)) {
            display = .list
        }
    }

    private func toggleCollectionMemorySelection(_ record: UserMapRecord) {
        guard let reference = record.journeyMemberReference else { return }
        guard collectionSelectionTarget?.memberReferences.contains(reference) != true else { return }

        if selectedCollectionMemoryReferences.contains(reference) {
            selectedCollectionMemoryReferences.remove(reference)
        } else {
            selectedCollectionMemoryReferences.insert(reference)
        }
    }

    private func completeCollectionMemorySelection() {
        let references = selectedCollectionReferencesInListOrder
        guard references.isEmpty == false else { return }
        isSearchFocused = false
        if collectionMemorySelection?.destinationFolderID == nil {
            isCollectionPickerPresented = true
            return
        }
        guard let target = collectionSelectionTarget,
              let updatedFolder = append(references, toJourneyFolder: target.id) else {
            cancelCollectionMemorySelection()
            return
        }

        finishCollectionMemorySelection()
        presentCollection(updatedFolder)
    }

    private func finishCollectionMemorySelection() {
        isSearchFocused = false
        isCollectionPickerPresented = false
        collectionMemorySelection = nil
        selectedCollectionMemoryReferences.removeAll()
    }

    private func cancelCollectionMemorySelection() {
        let target = collectionSelectionTarget
        let returnsToCollection = collectionMemorySelection?.destinationFolderID != nil
        finishCollectionMemorySelection()

        if let target {
            presentCollection(target)
        } else if returnsToCollection {
            presentCollectionsDirectory()
        }
    }

    private func presentCollectionsDirectory() {
        activeCollection = nil
        isJourneyCollectionsPresented = true
    }

    private func presentCollection(_ folder: JourneyFolder) {
        activeCollection = nil
        isJourneyCollectionsPresented = true
        DispatchQueue.main.async {
            activeCollection = folder
        }
    }

    private var isJourneyOrganizerTransactionActive: Bool {
        journeyOrganizerDrag != nil
            || journeyOrganizerDrop != nil
            || journeyOrganizerReturn != nil
            || journeyFolderMergeAnimation != nil
            || journeyFolderAppendAnimation != nil
            || journeyOrganizerRenamePendingFolder != nil
    }

    private var organizerChromeAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .spring(response: 0.34, dampingFraction: 0.86)
    }

    private var organizerLandingAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.01)
            : .spring(response: 0.3, dampingFraction: 0.82)
    }

    private var organizerLiftAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.01)
            : .spring(response: 0.18, dampingFraction: 0.88)
    }

    private var organizerMergeFlightAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.01)
            : .spring(response: 0.38, dampingFraction: 0.86)
    }

    private var organizerSettleAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.01)
            : .spring(response: 0.26, dampingFraction: 0.76)
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
        withAnimation(organizerChromeAnimation) {
            isOrganizingMapJourneys = true
        }
        journeyOrganizerSelectionFeedback.prepare()
    }

    private func finishMapJourneyOrganization() {
        guard isJourneyOrganizerTransactionActive == false else { return }
        journeyOrganizerDrag = nil
        journeyOrganizerDrop = nil
        journeyOrganizerReturn = nil
        isJourneyOrganizerDragLifted = false
        isJourneyOrganizerDropSettling = false
        isJourneyOrganizerReturning = false
        journeyOrganizerSourceInFlightID = nil
        journeyOrganizerSelectedRecordID = nil
        journeyOrganizerCompletedTarget = nil
        journeyOrganizerHoveredTarget = nil
        journeyOrganizerArmedTarget = nil
        journeyOrganizerHoverRevision &+= 1
        journeyOrganizerDockScrollRequestID = nil
        journeyOrganizerRenamePendingFolder = nil
        journeyFolderMergeAnimation = nil
        journeyFolderMergePhase = nil
        journeyFolderAppendAnimation = nil
        journeyFolderAppendPhase = nil
        withAnimation(organizerChromeAnimation) {
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

        // One hand can only hold one memory. Ignore any secondary gesture
        // until the current drop, return, or merge has reached a stable end.
        guard isJourneyOrganizerTransactionActive == false else { return }

        journeyOrganizerSelectedRecordID = record.id
        journeyOrganizerSourceInFlightID = record.id
        isJourneyOrganizerDragLifted = false
        clearMapJourneyHoverTarget()
        journeyOrganizerDrag = JourneyOrganizerDrag(
            record: record,
            reference: reference,
            startLocation: location,
            location: location
        )
        updateMapJourneyDrag(record, at: location)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        DispatchQueue.main.async {
            guard journeyOrganizerDrag?.record.id == record.id else { return }
            withAnimation(organizerLiftAnimation) {
                isJourneyOrganizerDragLifted = true
            }
        }
    }

    private func updateMapJourneyDrag(_ record: UserMapRecord, at location: CGPoint) {
        guard var drag = journeyOrganizerDrag,
              drag.record.id == record.id else {
            return
        }
        drag.location = location
        journeyOrganizerDrag = drag

        guard journeyOrganizerDragDistance(drag)
                >= JourneyOrganizerInteraction.minimumDragDistance else {
            clearMapJourneyHoverTarget()
            return
        }

        let nextTarget = journeyOrganizerTarget(
            at: location,
            excluding: record.id,
            reference: drag.reference
        )
        guard nextTarget != journeyOrganizerHoveredTarget else { return }

        journeyOrganizerHoverRevision &+= 1
        let hoverRevision = journeyOrganizerHoverRevision
        journeyOrganizerHoveredTarget = nextTarget
        journeyOrganizerArmedTarget = nil
        guard let nextTarget else { return }

        // Seeing a nearby marker is only a preview. It becomes a committed
        // drop target after the pointer remains inside the tighter acquisition
        // area long enough to make the person's intent unambiguous.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + JourneyOrganizerInteraction.targetArmDelay
        ) {
            guard journeyOrganizerHoverRevision == hoverRevision,
                  journeyOrganizerHoveredTarget == nextTarget,
                  let currentDrag = journeyOrganizerDrag,
                  currentDrag.record.id == record.id,
                  journeyOrganizerDragDistance(currentDrag)
                    >= JourneyOrganizerInteraction.minimumDragDistance,
                  targetContains(
                    nextTarget,
                    location: currentDrag.location,
                    excluding: record.id,
                    reference: currentDrag.reference,
                    padding: JourneyOrganizerInteraction.targetAcquisitionPadding
                  ) else {
                return
            }
            journeyOrganizerArmedTarget = nextTarget
            journeyOrganizerSelectionFeedback.selectionChanged()
            journeyOrganizerSelectionFeedback.prepare()
        }
    }

    private func endMapJourneyDrag(_ record: UserMapRecord, at location: CGPoint) {
        updateMapJourneyDrag(record, at: location)
        guard let drag = journeyOrganizerDrag,
              drag.record.id == record.id,
              journeyOrganizerDragDistance(drag)
                >= JourneyOrganizerInteraction.minimumDragDistance,
              let target = journeyOrganizerArmedTarget,
              journeyOrganizerHoveredTarget == target,
              targetContains(
                target,
                location: location,
                excluding: record.id,
                reference: drag.reference,
                padding: JourneyOrganizerInteraction.targetCommitPadding
              ),
              let landingLocation = journeyOrganizerLandingLocation(for: target) else {
            beginMapJourneyReturn(for: record)
            return
        }

        // Freeze the exact visible destination at release. The token is now
        // the one thing the eye follows through the complete transaction.
        let drop = JourneyOrganizerDrop(
            drag: drag,
            target: target,
            releaseLocation: journeyOrganizerTokenLocation(for: drag, toward: target),
            landingLocation: landingLocation
        )
        journeyOrganizerDrag = nil
        isJourneyOrganizerDragLifted = false
        journeyOrganizerCompletedTarget = target
        clearMapJourneyHoverTarget()
        journeyOrganizerDrop = drop
        isJourneyOrganizerDropSettling = false

        DispatchQueue.main.async {
            guard journeyOrganizerDrop?.id == drop.id else { return }
            withAnimation(organizerLandingAnimation) {
                isJourneyOrganizerDropSettling = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard journeyOrganizerDrop?.id == drop.id else { return }
            completeMapJourneyDrop(drop)
        }
    }

    private func beginMapJourneyReturn(for record: UserMapRecord) {
        guard let drag = journeyOrganizerDrag,
              drag.record.id == record.id else {
            return
        }
        let homeLocation = journeyOrganizerTargetFrames[.record(record.id)]
            .map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? drag.location
        let launchLocation = journeyOrganizerTokenLocation(
            for: drag,
            toward: journeyOrganizerHoveredTarget
        )
        journeyOrganizerDrag = nil
        isJourneyOrganizerDragLifted = false
        clearMapJourneyHoverTarget()
        let returning = JourneyOrganizerReturn(
            drag: drag,
            launchLocation: launchLocation,
            launchScale: 1,
            homeLocation: homeLocation
        )
        journeyOrganizerReturn = returning
        isJourneyOrganizerReturning = false

        DispatchQueue.main.async {
            guard journeyOrganizerReturn?.id == returning.id else { return }
            withAnimation(organizerLandingAnimation) {
                isJourneyOrganizerReturning = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard journeyOrganizerReturn?.id == returning.id else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                journeyOrganizerReturn = nil
                isJourneyOrganizerReturning = false
                journeyOrganizerSourceInFlightID = nil
            }
        }
    }

    private func cancelMapJourneyDrag(_ record: UserMapRecord) {
        beginMapJourneyReturn(for: record)
    }

    private func journeyOrganizerDragDistance(_ drag: JourneyOrganizerDrag) -> CGFloat {
        let dx = drag.location.x - drag.startLocation.x
        let dy = drag.location.y - drag.startLocation.y
        return sqrt(dx * dx + dy * dy)
    }

    private func clearMapJourneyHoverTarget() {
        guard journeyOrganizerHoveredTarget != nil
                || journeyOrganizerArmedTarget != nil else {
            return
        }
        journeyOrganizerHoverRevision &+= 1
        journeyOrganizerHoveredTarget = nil
        journeyOrganizerArmedTarget = nil
    }

    private func completeMapJourneyDrop(_ drop: JourneyOrganizerDrop) {
        switch drop.target {
        case let .folder(folderID):
            guard let folder = journeyFolders.first(where: { $0.id == folderID }),
                  folder.memberReferences.contains(drop.drag.reference) == false else {
                clearMapJourneyDrop(drop)
                return
            }

            // The root token has already travelled to this Folder's real
            // cover slot. The cover simply takes it over at that same spot.
            let animation = JourneyFolderAppendAnimation(
                folderID: folderID,
                sourceRecord: drop.drag.record,
                previousRecords: mapJourneyRecords(for: folder)
            )
            guard append([drop.drag.reference], toJourneyFolder: folderID) != nil else {
                clearMapJourneyDrop(drop)
                return
            }
            beginMapJourneyFolderAppendAnimation(animation, completing: drop)

        case let .record(recordID):
            guard recordID != drop.drag.record.id,
                  let other = mapRecords.first(where: { $0.id == recordID }),
                  let otherReference = other.journeyMemberReference else {
                clearMapJourneyDrop(drop)
                return
            }
            // Keep the source first in the folder's editable order, while
            // the cover shows latest content first. That makes both cells
            // retain their physical place as the new Folder reaches the rail.
            if let folder = createJourney(with: [drop.drag.reference, otherReference]) {
                beginMapJourneyFolderMergeAnimation(
                    folder: folder,
                    source: drop.drag.record,
                    target: other,
                    completing: drop
                )
            } else {
                clearMapJourneyDrop(drop)
            }
        }
    }

    private func journeyOrganizerTarget(
        at location: CGPoint,
        excluding sourceRecordID: UUID,
        reference: JourneyFolder.MemberReference
    ) -> JourneyOrganizerTarget? {
        // Once a target has caught the marker, give it a larger exit radius.
        // This avoids the harsh on/off flicker caused by sampling a moving
        // finger around a target boundary.
        if let hovered = journeyOrganizerHoveredTarget,
           journeyOrganizerArmedTarget == hovered,
           targetContains(
                hovered,
                location: location,
                excluding: sourceRecordID,
                reference: reference,
                padding: hoveredExitPadding(for: hovered)
           ) {
            return hovered
        }

        // A drop should feel forgiving: folders take priority in their dock,
        // while map pins receive a slightly larger magnetic catchment area.
        let folderCandidates = journeyOrganizerTargetFrames.compactMap { target, frame -> (JourneyOrganizerTarget, CGFloat)? in
            switch target {
            case .folder:
                guard targetContains(
                    target,
                    location: location,
                    excluding: sourceRecordID,
                    reference: reference,
                    padding: JourneyOrganizerInteraction.targetAcquisitionPadding
                ) else { return nil }
                return (target, distanceSquared(from: location, to: .init(x: frame.midX, y: frame.midY)))
            case .record:
                return nil
            }
        }
        if let folderTarget = folderCandidates.min(by: { $0.1 < $1.1 })?.0 {
            return folderTarget
        }

        // The rail is a private organizer surface. A map marker that happens
        // to sit behind a gap between folders must not become an invisible
        // receiver when the person releases over the dock.
        guard isInsideJourneyOrganizerDock(location) == false else { return nil }

        let recordCandidates = journeyOrganizerTargetFrames.compactMap { target, frame -> (JourneyOrganizerTarget, CGFloat)? in
            guard case let .record(recordID) = target,
                  recordID != sourceRecordID else {
                return nil
            }

            guard targetContains(
                target,
                location: location,
                excluding: sourceRecordID,
                reference: reference,
                padding: JourneyOrganizerInteraction.targetAcquisitionPadding
            ) else { return nil }
            return (target, distanceSquared(from: location, to: .init(x: frame.midX, y: frame.midY)))
        }
        return recordCandidates.min(by: { $0.1 < $1.1 })?.0
    }

    private func targetContains(
        _ target: JourneyOrganizerTarget,
        location: CGPoint,
        excluding sourceRecordID: UUID,
        reference: JourneyFolder.MemberReference,
        padding: CGFloat
    ) -> Bool {
        guard let frame = journeyOrganizerTargetFrames[target] else { return false }

        switch target {
        case let .folder(folderID):
            guard journeyFolderCanReceive(reference, in: folderID) else { return false }
            return frame.insetBy(dx: -padding, dy: -padding).contains(location)
        case let .record(recordID):
            guard recordID != sourceRecordID else { return false }
            guard isInsideJourneyOrganizerDock(location) == false else { return false }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let dx = location.x - center.x
            let dy = location.y - center.y
            let radius = max(frame.width, frame.height) / 2 + padding
            return (dx * dx) + (dy * dy) <= radius * radius
        }
    }

    private func hoveredExitPadding(for _: JourneyOrganizerTarget) -> CGFloat {
        JourneyOrganizerInteraction.targetRetentionPadding
    }

    private func distanceSquared(from point: CGPoint, to center: CGPoint) -> CGFloat {
        let dx = point.x - center.x
        let dy = point.y - center.y
        return (dx * dx) + (dy * dy)
    }

    private func isInsideJourneyOrganizerDock(_ location: CGPoint) -> Bool {
        if journeyOrganizerDockFrame.isEmpty == false {
            return journeyOrganizerDockFrame
                .insetBy(dx: -4, dy: -4)
                .contains(location)
        }

        // Fallback for the first layout pass before the glass has published
        // its own frame. This path should only exist for a single frame.
        let folderFrames = journeyOrganizerTargetFrames.compactMap { target, frame -> CGRect? in
            guard case .folder = target else { return nil }
            return frame
        }
        guard let first = folderFrames.first else { return false }
        let dockFrame = folderFrames.dropFirst().reduce(first) { partial, frame in
            partial.union(frame)
        }
        return dockFrame.insetBy(dx: -10, dy: -10).contains(location)
    }

    private func journeyFolderCanReceive(
        _ reference: JourneyFolder.MemberReference,
        in folderID: UUID
    ) -> Bool {
        journeyFolders.first(where: { $0.id == folderID })?
            .memberReferences
            .contains(reference) == false
    }

    private func journeyOrganizerLandingLocation(
        for target: JourneyOrganizerTarget
    ) -> CGPoint? {
        switch target {
        case let .folder(folderID):
            guard let cover = journeyOrganizerCoverFrame(for: folderID) else { return nil }
            return JourneyFolderCoverLayout.slotCenter(in: cover, at: 0)

        case .record:
            guard let frame = journeyOrganizerTargetFrames[target] else { return nil }
            // The source lands in the empty top-right cell of the receiver
            // that forms around the target memory.
            let offset = JourneyFolderCoverLayout.slotOffset(for: 1)
            return CGPoint(x: frame.midX + offset.width, y: frame.midY + offset.height)
        }
    }

    /// The cover publishes its own frame for pixel-perfect landings. On the
    /// first layout pass, however, the tile frame arrives first; deriving the
    /// cover from it is visually equivalent and prevents a valid drop from
    /// failing just because a preference has not arrived yet.
    private func journeyOrganizerCoverFrame(for folderID: UUID) -> CGRect? {
        if let cover = journeyFolderCoverFrames[folderID] {
            return cover
        }

        guard let tile = journeyOrganizerTargetFrames[.folder(folderID)] else {
            return nil
        }

        return CGRect(
            x: tile.midX - JourneyFolderCoverLayout.size / 2,
            y: tile.minY,
            width: JourneyFolderCoverLayout.size,
            height: JourneyFolderCoverLayout.size
        )
    }

    private func overlayPosition(
        for location: CGPoint,
        in proxy: GeometryProxy
    ) -> CGPoint {
        let rootFrame = proxy.frame(in: JourneyOrganizerCoordinateSpace.space)
        return CGPoint(
            x: location.x - rootFrame.minX,
            y: location.y - rootFrame.minY
        )
    }

    private func journeyOrganizerTokenLocation(
        for drag: JourneyOrganizerDrag,
        toward target: JourneyOrganizerTarget?
    ) -> CGPoint {
        let pointerLocation = CGPoint(
            x: drag.location.x,
            y: drag.location.y - 26
        )

        guard let target,
              let targetLocation = journeyOrganizerLandingLocation(for: target) else {
            return pointerLocation
        }

        // A real object stays under the person's finger. The target can make
        // a small magnetic pull, but the lifted memory never teleports to the
        // destination before it is released.
        let dx = targetLocation.x - pointerLocation.x
        let dy = targetLocation.y - pointerLocation.y
        let distance = max(sqrt(dx * dx + dy * dy), 0.001)
        let maximumPull: CGFloat = {
            switch target {
            case .record: 8
            case .folder: 10
            }
        }()
        let pull = min(maximumPull, distance * 0.16)
        return CGPoint(
            x: pointerLocation.x + (dx / distance) * pull,
            y: pointerLocation.y + (dy / distance) * pull
        )
    }

    private func mapJourneyDragPreviewPosition(
        for drag: JourneyOrganizerDrag,
        in proxy: GeometryProxy
    ) -> CGPoint {
        overlayPosition(
            for: journeyOrganizerTokenLocation(
                for: drag,
                toward: journeyOrganizerHoveredTarget
            ),
            in: proxy
        )
    }

    private func mapJourneyDropPosition(
        for drop: JourneyOrganizerDrop,
        in proxy: GeometryProxy
    ) -> CGPoint {
        guard isJourneyOrganizerDropSettling else {
            return overlayPosition(for: drop.releaseLocation, in: proxy)
        }
        return overlayPosition(for: drop.landingLocation, in: proxy)
    }

    private func mapJourneyReturnPosition(
        for returning: JourneyOrganizerReturn,
        in proxy: GeometryProxy
    ) -> CGPoint {
        guard isJourneyOrganizerReturning else {
            return overlayPosition(for: returning.launchLocation, in: proxy)
        }
        return overlayPosition(for: returning.homeLocation, in: proxy)
    }

    @ViewBuilder
    private func mapJourneyFolderMergeAnimation(
        _ merge: JourneyFolderMergeAnimation,
        phase: JourneyFolderMergePhase,
        in proxy: GeometryProxy
    ) -> some View {
        let mapTarget = overlayPosition(for: merge.origin, in: proxy)
        // The new rail tile can take one render pass to publish its frame.
        // Once it has, the exact destination is frozen for the whole flight
        // so a layout pass can never bend the path.
        let shelfDestination = merge.shelfDestination.map {
            overlayPosition(for: $0, in: proxy)
        } ?? mapTarget
        let containerPosition: CGPoint = switch phase {
        case .receiving:
            mapTarget
        case .traveling, .settled:
            shelfDestination
        }
        let isSourceInside = phase == .traveling || phase == .settled

        MapJourneyFolderMergeContainer(
            sourceRecord: merge.sourceRecord,
            targetRecord: merge.targetRecord,
            showsSourceInside: isSourceInside
        )
        .position(containerPosition)
        .opacity(phase == .settled ? 0.01 : 1)
        .animation(organizerMergeFlightAnimation, value: phase)
    }

    private func beginMapJourneyFolderMergeAnimation(
        folder: JourneyFolder,
        source: UserMapRecord,
        target: UserMapRecord,
        completing drop: JourneyOrganizerDrop
    ) {
        let merge = JourneyFolderMergeAnimation(
            folder: folder,
            sourceRecord: source,
            targetRecord: target,
            origin: CGPoint(
                x: drop.landingLocation.x - JourneyFolderCoverLayout.slotOffset(for: 1).width,
                y: drop.landingLocation.y - JourneyFolderCoverLayout.slotOffset(for: 1).height
            )
        )
        journeyFolderMergeAnimation = merge
        journeyFolderMergePhase = .receiving

        // The source token is still visible in the receiver's open cell.
        // Once the container starts travelling, it takes ownership of that
        // exact token and becomes the completed Folder.
        schedulePendingMapJourneyFolderMergeIfReady()

        // Preferences normally arrive on the next render pass. If a layout
        // interruption prevents that, the Folder has still been created and
        // the organizer must never remain locked waiting for an animation
        // destination that no longer exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            finishMapJourneyFolderMergeWithoutFlight(
                mergeID: merge.id,
                dropID: drop.id
            )
        }
    }

    /// A newly-created Folder only becomes a valid physical destination after
    /// its rail tile has published a visible frame. Preference updates, rather
    /// than a guessed timeout, start the flight exactly when that is true.
    private func schedulePendingMapJourneyFolderMergeIfReady() {
        guard let merge = journeyFolderMergeAnimation,
              journeyFolderMergePhase == .receiving,
              let drop = journeyOrganizerDrop else {
            return
        }

        DispatchQueue.main.async {
            advanceMapJourneyFolderMerge(
                mergeID: merge.id,
                dropID: drop.id
            )
        }
    }

    private func advanceMapJourneyFolderMerge(
        mergeID: UUID,
        dropID: UUID
    ) {
        guard var merge = journeyFolderMergeAnimation,
              merge.id == mergeID,
              journeyFolderMergePhase == .receiving,
              journeyOrganizerDrop?.id == dropID else {
            return
        }

        guard let coverFrame = journeyOrganizerCoverFrame(for: merge.folder.id) else {
            journeyOrganizerDockScrollRequestID = merge.folder.id
            return
        }

        guard isVisibleJourneyFolderCover(coverFrame) else {
            journeyOrganizerDockScrollRequestID = merge.folder.id
            return
        }

        merge.shelfDestination = CGPoint(x: coverFrame.midX, y: coverFrame.midY)
        withAnimation(organizerMergeFlightAnimation) {
            journeyFolderMergeAnimation = merge
            journeyFolderMergePhase = .traveling
            journeyOrganizerDockScrollRequestID = nil
            journeyOrganizerDrop = nil
            isJourneyOrganizerDropSettling = false
            journeyOrganizerCompletedTarget = nil
            journeyOrganizerSourceInFlightID = nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            settleMapJourneyFolderMerge(mergeID: mergeID)
        }
    }

    private func isVisibleJourneyFolderCover(_ frame: CGRect) -> Bool {
        guard mapSize.width > 1, mapSize.height > 1 else { return false }
        return frame.maxX > 0 && frame.minX < mapSize.width
            && frame.maxY > 0 && frame.minY < mapSize.height
    }

    private func settleMapJourneyFolderMerge(mergeID: UUID) {
        guard let merge = journeyFolderMergeAnimation,
              merge.id == mergeID else { return }
        withAnimation(organizerSettleAnimation) {
            journeyFolderMergePhase = .settled
            // A missing rail frame is rare, but it should never strand the
            // root token. This fallback preserves the completed Folder and
            // allows the dock to take over when it arrives.
            journeyOrganizerDrop = nil
            isJourneyOrganizerDropSettling = false
            journeyOrganizerCompletedTarget = nil
            journeyOrganizerSourceInFlightID = nil
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            guard journeyFolderMergeAnimation?.id == mergeID else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                journeyFolderMergeAnimation = nil
                journeyFolderMergePhase = nil
            }

            requestMapJourneyFolderName(for: merge.folder)
        }
    }

    /// Layout failure must degrade to a completed folder in the rail, not a
    /// frozen map. The model write already happened before this animation;
    /// this simply skips the non-essential flight when no safe destination
    /// can be measured.
    private func finishMapJourneyFolderMergeWithoutFlight(
        mergeID: UUID,
        dropID: UUID
    ) {
        guard let merge = journeyFolderMergeAnimation,
              merge.id == mergeID,
              journeyFolderMergePhase == .receiving,
              journeyOrganizerDrop?.id == dropID else {
            return
        }

        journeyOrganizerRenamePendingFolder = merge.folder
        withAnimation(.easeOut(duration: 0.16)) {
            journeyFolderMergeAnimation = nil
            journeyFolderMergePhase = nil
            journeyOrganizerDrop = nil
            isJourneyOrganizerDropSettling = false
            journeyOrganizerCompletedTarget = nil
            journeyOrganizerSourceInFlightID = nil
            journeyOrganizerDockScrollRequestID = nil
        }
        requestMapJourneyFolderName(for: merge.folder, isAlreadyPending: true)
    }

    private func requestMapJourneyFolderName(
        for folder: JourneyFolder,
        isAlreadyPending: Bool = false
    ) {
        if isAlreadyPending == false {
            // Keep the organizer transaction closed across the tiny gap
            // before the sheet appears. Done or a second drag must not race
            // the default naming step.
            journeyOrganizerRenamePendingFolder = folder
        }

        // Naming is a follow-up edit, never a modal interruption between the
        // gesture and its physical result. Wait until the container has fully
        // handed off to the rail before bringing up the keyboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard isOrganizingMapJourneys,
                  journeyFolderRenameRequest == nil,
                  journeyOrganizerRenamePendingFolder?.id == folder.id else {
                if journeyOrganizerRenamePendingFolder?.id == folder.id {
                    journeyOrganizerRenamePendingFolder = nil
                }
                return
            }
            journeyFolderRenameRequest = JourneyFolderRenameRequest(folder: folder)
            journeyOrganizerRenamePendingFolder = nil
        }
    }

    private func beginMapJourneyFolderAppendAnimation(
        _ animation: JourneyFolderAppendAnimation,
        completing drop: JourneyOrganizerDrop
    ) {
        journeyFolderAppendAnimation = animation
        journeyFolderAppendPhase = .receiving

        // The same root token is already sitting over the open slot. Cross it
        // into the persistent mosaic in place instead of creating another
        // thumbnail that appears from the Folder centre.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            guard journeyFolderAppendAnimation?.id == animation.id,
                  journeyOrganizerDrop?.id == drop.id else { return }
            withAnimation(organizerSettleAnimation) {
                journeyFolderAppendPhase = .settled
                journeyOrganizerDrop = nil
                isJourneyOrganizerDropSettling = false
                journeyOrganizerCompletedTarget = nil
                journeyOrganizerSourceInFlightID = nil
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            guard journeyFolderAppendAnimation?.id == animation.id else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                journeyFolderAppendAnimation = nil
                journeyFolderAppendPhase = nil
            }
        }
    }

    private func clearMapJourneyDrop(_ drop: JourneyOrganizerDrop) {
        guard journeyOrganizerDrop?.id == drop.id else { return }
        returnMapJourneyDropToSource(drop)
    }

    /// A destination can still become invalid if its backing data changes
    /// between hover and release. Treat that as a cancelled drop, never as a
    /// silent disappearance that looks like a successful save.
    private func returnMapJourneyDropToSource(_ drop: JourneyOrganizerDrop) {
        guard journeyOrganizerDrop?.id == drop.id else { return }
        let homeLocation = journeyOrganizerTargetFrames[.record(drop.drag.record.id)]
            .map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? drop.drag.location
        let returning = JourneyOrganizerReturn(
            drag: drop.drag,
            launchLocation: drop.landingLocation,
            launchScale: JourneyFolderCoverLayout.landingTokenScale,
            homeLocation: homeLocation
        )

        journeyOrganizerDrop = nil
        isJourneyOrganizerDropSettling = false
        journeyOrganizerCompletedTarget = nil
        journeyOrganizerReturn = returning
        isJourneyOrganizerReturning = false

        DispatchQueue.main.async {
            guard journeyOrganizerReturn?.id == returning.id else { return }
            withAnimation(organizerLandingAnimation) {
                isJourneyOrganizerReturning = true
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard journeyOrganizerReturn?.id == returning.id else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                journeyOrganizerReturn = nil
                isJourneyOrganizerReturning = false
                journeyOrganizerSourceInFlightID = nil
            }
        }
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
        return onCreateJourneyFolder("Untitled Collection", uniqueReferences)
    }

    /// A map-created folder is provisional until its naming step is accepted.
    /// Its members are only references, so deleting it restores the map to
    /// exactly the state it had before the two markers were brought together.
    private func cancelMapJourneyFolderCreation(_ folder: JourneyFolder) {
        guard journeyFolders.contains(where: { $0.id == folder.id }) else { return }
        journeyFolderRenameRequest = nil
        journeyOrganizerRenamePendingFolder = nil
        journeyOrganizerDockScrollRequestID = nil
        onDeleteJourneyFolder(folder.id)
    }

    @discardableResult
    private func append(
        _ references: [JourneyFolder.MemberReference],
        toJourneyFolder folderID: UUID
    ) -> JourneyFolder? {
        guard var folder = journeyFolders.first(where: { $0.id == folderID }) else { return nil }
        let newReferences = references.filter { folder.memberReferences.contains($0) == false }
        guard newReferences.isEmpty == false else { return nil }
        folder.memberReferences.append(contentsOf: newReferences)
        onSaveJourneyFolder(folder)
        return folder
    }

    private var listContent: some View {
        ScrollViewReader { proxy in
            List {
                if filteredRecords.isEmpty {
                    archiveEmptyState
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(groupedRecords, id: \.0) { section in
                        archiveSection(section)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.bottom, 94, for: .scrollContent)
            // Keep this inset on the List itself. A parent safe-area inset
            // does not participate in List's pinned-header layout on recent
            // iOS versions, which was why the first memory appeared beneath
            // the search and filter bar.
            .safeAreaInset(edge: .top, spacing: 0) {
                archiveControls
            }
            .onAppear {
                restoreListPosition(using: proxy)
            }
        }
        .background(Color(.systemBackground))
    }

    /// A private collection has no coordinate. In arrange mode it lives in a
    /// compact, horizontally-scrollable photo rail above the tab bar rather
    /// than as a map pin. It only appears after the person explicitly chooses
    /// to organize, like a temporary workspace rather than map content.
    @ViewBuilder
    private var mapJourneyDock: some View {
        if journeyFolders.isEmpty == false {
            mapJourneyDropDock
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
                )
        }
    }

    @ViewBuilder
    private var mapJourneyDropDock: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                mapJourneyDropDockTiles
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .onChangeCompat(of: journeyOrganizerDockScrollRequestID) { folderID in
                guard let folderID else { return }
                withAnimation(
                    reduceMotion
                        ? .linear(duration: 0.01)
                        : .easeOut(duration: 0.18)
                ) {
                    proxy.scrollTo(folderID, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.58), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.16), radius: 18, y: 8)
        .background(mapJourneyOrganizerDockFrame)
        .accessibilityIdentifier("mymap.journey-dock")
    }

    private var mapJourneyOrganizerDockFrame: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: JourneyOrganizerDockFramePreferenceKey.self,
                value: proxy.frame(in: JourneyOrganizerCoordinateSpace.space)
            )
        }
        .allowsHitTesting(false)
    }

    private var mapJourneyDropDockTiles: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(journeyFolders) { folder in
                mapJourneyFolderTarget(
                    folder,
                    records: mapJourneyRecords(for: folder)
                )
                .id(folder.id)
            }
        }
    }

    @ViewBuilder
    private func mapJourneyFolderTarget(
        _ folder: JourneyFolder,
        records: [UserMapRecord]
    ) -> some View {
        let target = JourneyOrganizerTarget.folder(folder.id)
        let isMergeFolder = journeyFolderMergeAnimation?.folder.id == folder.id
        let mergePhase = isMergeFolder ? journeyFolderMergePhase : nil
        let appendAnimation = journeyFolderAppendAnimation?.folderID == folder.id
            ? journeyFolderAppendAnimation
            : nil
        let appendPhase = appendAnimation == nil ? nil : journeyFolderAppendPhase
        let isInTransit = mergePhase == .receiving
            || mergePhase == .traveling
        let isArriving = mergePhase == .settled || appendPhase == .settled
        let isDropTarget = isOrganizingMapJourneys && (
            journeyOrganizerHoveredTarget == target || journeyOrganizerCompletedTarget == target
        )
        let hasOtherActiveTarget = journeyOrganizerHoveredTarget != nil && isDropTarget == false
        let tile = mapJourneyFolderRailTile(
            folder,
            records: records,
            isDropTarget: isDropTarget,
            appendAnimation: appendAnimation,
            appendPhase: appendPhase,
            mergePhase: mergePhase,
            isArriving: isArriving
        )
            // Only the organizer tile publishes geometry. The normal browse
            // rail reuses this exact tile visual without becoming a second,
            // invisible drop target.
            .background(mapJourneyFolderCoverFrame(folder.id))
            .opacity(isInTransit ? 0 : (hasOtherActiveTarget ? 0.84 : 1))
            .shadow(
                color: Color.black.opacity(isDropTarget ? 0.2 : 0.06),
                radius: isDropTarget ? 10 : 4,
                y: isDropTarget ? 5 : 2
            )
            .animation(organizerSettleAnimation, value: journeyOrganizerHoveredTarget)
            .background(mapJourneyTargetFrame(target))

        tile
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Collection: \(folder.title)")
            .accessibilityValue("\(folder.memberReferences.count) memories")
            .accessibilityIdentifier("mymap.map-journey-folder.\(folder.id.uuidString)")
    }

    /// The browse shelf and the organize dock intentionally share this whole
    /// tile, not merely an icon. It keeps a private folder recognisable while
    /// it goes from a quiet map handle, to a browse rail, to a drop target.
    private func mapJourneyFolderRailTile(
        _ folder: JourneyFolder,
        records: [UserMapRecord],
        isDropTarget: Bool,
        appendAnimation: JourneyFolderAppendAnimation?,
        appendPhase: JourneyFolderAppendPhase?,
        mergePhase: JourneyFolderMergePhase?,
        isArriving: Bool
    ) -> some View {
        VStack(spacing: 6) {
            MapJourneyFolderDockCover(
                records: records,
                isDropTarget: isDropTarget,
                appendAnimation: appendAnimation,
                appendPhase: appendPhase,
                size: JourneyFolderCoverLayout.size
            )
            // Keep the receiver's slot completely still while a token is
            // travelling toward it. The tiny post-landing settle happens only
            // after ownership has passed to the cover.
            .scaleEffect(isArriving && reduceMotion == false ? 1.022 : 1)
            .animation(
                organizerSettleAnimation,
                value: mergePhase
            )
            .animation(
                organizerSettleAnimation,
                value: appendPhase
            )

            Text(folder.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.primary.opacity(0.9))
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.82)
            .frame(width: 72, height: 16, alignment: .top)
        }
        .frame(width: 72)
    }

    private func mapJourneyRecords(for folder: JourneyFolder) -> [UserMapRecord] {
        // A Folder cover behaves like a living album cover: the thing that
        // just entered stays visible rather than flashing in and disappearing
        // when the temporary landing state ends. The editable order inside
        // the Folder itself remains unchanged.
        folder.memberReferences.reversed().compactMap { reference in
            switch reference {
            case let .reel(id):
                guard let reel = reels.first(where: { $0.id == id }) else { return nil }
                return UserMapRecord(id: reel.id, timestamp: reel.activityDate, kind: .reel(reel))

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
                value: [target: proxy.frame(in: JourneyOrganizerCoordinateSpace.space)]
            )
        }
    }

    private func mapJourneyFolderCoverFrame(_ folderID: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: JourneyFolderCoverFramePreferenceKey.self,
                value: [folderID: proxy.frame(in: JourneyOrganizerCoordinateSpace.space)]
            )
        }
    }

    private func mapJourneyWiggle(for id: UUID) -> Double {
        id.uuidString.hashValue.isMultiple(of: 2) ? 1 : -1
    }


    private var archiveEmptyState: some View {
        ContentUnavailableView(
            "No memories found",
            systemImage: "magnifyingglass",
            description: Text("Try a different search or filter.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func archiveSection(_ section: (String, [UserMapRecord])) -> some View {
        Section {
            ForEach(section.1.indices, id: \.self) { index in
                let record = section.1[index]
                archiveRecordRow(record)
                    .id(record.id)
                    .listRowInsets(.init(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .overlay(alignment: .bottom) {
                        if index < section.1.count - 1 {
                            Divider()
                                .padding(.leading, 76)
                        }
                    }
            }
        } header: {
            // The native header is intentionally sticky. Its surface must be
            // taller than its text so a card can never show through the
            // otherwise-transparent edges of List's pinned-header host.
            ArchiveDateHeader(
                title: section.0,
                count: section.1.count,
                date: section.1.first?.timestamp ?? .now
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
        }
    }

    @ViewBuilder
    private func archiveRecordRow(_ record: UserMapRecord) -> some View {
        if isSelectingCollectionMemories {
            collectionSelectionRow(record)
        } else {
            archiveBrowsingRow(record)
        }
    }

    private func archiveBrowsingRow(_ record: UserMapRecord) -> some View {
        let publication = record.pendingPublication(in: pendingPublications)
        return HStack(spacing: 0) {
            Button {
                openRecordFromList(record)
            } label: {
                UserMapRecordCard(record: record)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ArchiveRecordButtonStyle())
            .accessibilityIdentifier("mymap.list-record.\(record.id.uuidString)")
            .backendPostActions(for: record.journeyMemberReference, ownerID: user.id)

            if let publication, case .failed = publication.status {
                Button {
                    onRetryPublication(publication.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry publication")
                .accessibilityHint("Your memory is saved on this device but has not been published yet.")
                .accessibilityIdentifier("mymap.retry-publication.\(publication.id.uuidString)")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                recordPendingRemoval = record
            } label: {
                Label(deletesPublishedPosts ? "Delete" : "Remove", systemImage: "trash")
            }
            .tint(.red)
            .accessibilityLabel(deletesPublishedPosts ? "Delete from MyMap and feed" : "Remove from MyMap")
        }
    }

    private func collectionSelectionRow(_ record: UserMapRecord) -> some View {
        let reference = record.journeyMemberReference
        let isAlreadyInTarget = reference.map {
            collectionSelectionTarget?.memberReferences.contains($0) == true
        } ?? false
        let isSelected = reference.map(selectedCollectionMemoryReferences.contains) ?? false

        return Button {
            toggleCollectionMemorySelection(record)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isAlreadyInTarget || isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(
                        isAlreadyInTarget
                            ? Color.secondary
                            : (isSelected ? Color.primary : Color.secondary)
                    )

                UserMapRecordCard(record: record)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(ArchiveRecordButtonStyle())
        .disabled(isAlreadyInTarget || reference == nil)
        .accessibilityIdentifier("mymap.list-record.\(record.id.uuidString)")
        .accessibilityLabel(record.title)
        .accessibilityValue(isAlreadyInTarget ? "Already in collection" : (isSelected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var mapContent: some View {
        MapReader { mapProxy in
            GeometryReader { geometry in
                let hitClusters = mapMemoryHitClusters(
                    using: mapProxy,
                    size: geometry.size
                )

                Map(
                    position: $cameraPosition,
                    // Empty map space remains fully explorable in organize
                    // mode. Once a memory is in a transaction, freeze the
                    // canvas until it reaches its frozen destination.
                    interactionModes: isJourneyOrganizerTransactionActive ? [] : .all
                ) {
                    ForEach(mapRecordsForRendering) { record in
                        Annotation("", coordinate: record.coordinate) {
                            // MapKit owns spatial rendering; interaction is a
                            // stable overlay, so a long press never replaces
                            // the annotation beneath the user's finger.
                            mapMarkerVisual(for: record)
                                .allowsHitTesting(false)
                        }
                    }
                }
                // Keep canvas semantics on MapKit, not its interactive pin overlay.
                // Applying these after overlay overwrites each memory button's label/ID.
                .accessibilityIdentifier("mymap.map-canvas")
                .accessibilityLabel("MyMap map")
                .accessibilityValue(mapScopeAccessibilityValue)
                .overlay {
                    mapOrganizerHitLayer(
                        clusters: hitClusters,
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
        clusters: [MapMemoryHitCluster],
        size: CGSize,
        safeAreaBottom: CGFloat
    ) -> some View {
        // Reading the revision keeps the hit layer aligned while the person
        // pans the map. The layer has no full-screen hit shape, so blank map
        // space continues straight through to MapKit.
        let _ = mapOverlayRevision
        ForEach(clusters) { cluster in
            mapMemoryHitClusterTarget(
                cluster,
                size: size,
                safeAreaBottom: safeAreaBottom
            )
            .position(cluster.point)
            .zIndex(100)
        }
    }

    private func isVisibleMapPoint(_ point: CGPoint, in size: CGSize) -> Bool {
        let hitRadius: CGFloat = 36
        return point.x >= -hitRadius && point.x <= size.width + hitRadius
            && point.y >= -hitRadius && point.y <= size.height + hitRadius
    }

    private var mapRecordsForRendering: [UserMapRecord] {
        guard isOrganizingMapJourneys,
              let selectedID = journeyOrganizerSelectedRecordID else {
            return mapRecords
        }

        // Keep the chosen member at the same coordinate but render it above
        // the rest of its stack. Cycling therefore changes the visible marker
        // rather than fanning the map apart.
        return mapRecords.enumerated()
            .sorted { lhs, rhs in
                let leftIsSelected = lhs.element.id == selectedID
                let rightIsSelected = rhs.element.id == selectedID
                if leftIsSelected != rightIsSelected {
                    return leftIsSelected == false
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func mapMemoryHitClusters(
        using mapProxy: MapProxy,
        size: CGSize
    ) -> [MapMemoryHitCluster] {
        let projected = mapRecords.compactMap { record -> (record: UserMapRecord, point: CGPoint)? in
            guard let point = mapProxy.convert(record.coordinate, to: .local),
                  isVisibleMapPoint(point, in: size) else {
                return nil
            }
            return (record, point)
        }

        // Only build a stack when icons physically overlap. Nearby but still
        // separately visible pins retain their individual one-tap targets.
        let overlapRadius: CGFloat = 34
        var clusters: [[(record: UserMapRecord, point: CGPoint)]] = []

        for item in projected {
            if let clusterIndex = clusters.indices.first(where: { index in
                clusters[index].contains {
                    distanceSquared(from: item.point, to: $0.point)
                        <= overlapRadius * overlapRadius
                }
            }) {
                clusters[clusterIndex].append(item)
            } else {
                clusters.append([item])
            }
        }

        return clusters.map { cluster in
            let anchor = cluster.reduce(CGPoint.zero) { partial, layout in
                CGPoint(
                    x: partial.x + layout.point.x / CGFloat(cluster.count),
                    y: partial.y + layout.point.y / CGFloat(cluster.count)
                )
            }
            return MapMemoryHitCluster(
                records: cluster.map(\.record),
                point: anchor
            )
        }
    }

    @ViewBuilder
    private func mapMemoryHitClusterTarget(
        _ cluster: MapMemoryHitCluster,
        size: CGSize,
        safeAreaBottom: CGFloat
    ) -> some View {
        let dragRecord = organizerRecord(in: cluster)
        let isStack = cluster.records.count > 1

        Button {
            guard journeyOrganizerDrag == nil,
                  isJourneyOrganizerTransactionActive == false else {
                return
            }

            if isOrganizingMapJourneys {
                // A short tap in arrange mode is a quiet selector, never a
                // card. On a stack it brings the next underlying memory to
                // the front so the next hold picks up that one.
                selectNextOrganizerRecord(in: cluster)
            } else {
                let record = nextBrowsingRecord(in: cluster)
                selectOnMap(record, size: size, safeAreaBottom: safeAreaBottom)
            }
        } label: {
            Group {
                if isOrganizingMapJourneys {
                    // Dragging only exists after a person explicitly enters
                    // Collections → Organize. The normal map remains a calm
                    // place to browse, pan and open memories.
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 64, height: 64)
                        .contentShape(Circle())
                        .gesture(
                            MapOrganizerPressGesture(
                                isOrganizing: true,
                                onBegan: { location in
                                    guard dragRecord.journeyMemberReference != nil else { return }
                                    beginMapJourneyDrag(dragRecord, at: location)
                                },
                                onChanged: { location in
                                    updateMapJourneyDrag(dragRecord, at: location)
                                },
                                onEnded: { location in
                                    endMapJourneyDrag(dragRecord, at: location)
                                },
                                onCancelled: {
                                    cancelMapJourneyDrag(dragRecord)
                                }
                            )
                        )
                } else {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 64, height: 64)
                        .contentShape(Circle())
                }
            }
        }
        .buttonStyle(.plain)
        .background(mapMarkerClusterTargetFrame(for: cluster))
        .accessibilityLabel(isStack ? "Overlapping memories" : dragRecord.title)
        .accessibilityValue(isStack ? dragRecord.title : "")
        .accessibilityHint(
            isOrganizingMapJourneys
                ? (isStack
                    ? "Tap to switch the selected memory. Hold briefly, then drag it."
                    : "Hold briefly, then drag into another memory or Journey")
                : (isStack
                    ? "Tap again to switch between memories."
                    : "Double tap to open.")
        )
        .accessibilityIdentifier(
            isStack
                ? "mymap.map-marker-stack.\(cluster.id)"
                : "mymap.map-marker.\(dragRecord.id.uuidString)"
        )
    }

    private func nextBrowsingRecord(in cluster: MapMemoryHitCluster) -> UserMapRecord {
        guard let currentID = mapSelectedRecord?.id,
              let currentIndex = cluster.records.firstIndex(where: { $0.id == currentID }) else {
            return cluster.defaultRecord
        }
        return cluster.records[(currentIndex + 1) % cluster.records.count]
    }

    private func organizerRecord(in cluster: MapMemoryHitCluster) -> UserMapRecord {
        if let selectedID = journeyOrganizerSelectedRecordID,
           let selected = cluster.records.first(where: { $0.id == selectedID }) {
            return selected
        }
        if let browsingSelection = mapSelectedRecord,
           let selected = cluster.records.first(where: { $0.id == browsingSelection.id }) {
            return selected
        }
        return cluster.defaultRecord
    }

    private func selectNextOrganizerRecord(in cluster: MapMemoryHitCluster) {
        let current = organizerRecord(in: cluster)
        guard let currentIndex = cluster.records.firstIndex(where: { $0.id == current.id }) else {
            return
        }
        let next = cluster.records[(currentIndex + 1) % cluster.records.count]
        guard next.id != journeyOrganizerSelectedRecordID else { return }

        withAnimation(organizerLiftAnimation) {
            journeyOrganizerSelectedRecordID = next.id
        }
        if cluster.records.count > 1 {
            journeyOrganizerSelectionFeedback.selectionChanged()
            journeyOrganizerSelectionFeedback.prepare()
        }
    }

    private func mapMarkerVisual(for record: UserMapRecord) -> some View {
        let recordTarget = JourneyOrganizerTarget.record(record.id)
        let isDropTarget = journeyOrganizerHoveredTarget == recordTarget
            || journeyOrganizerCompletedTarget == recordTarget
        let mergeOwnsReceiver = journeyFolderMergeAnimation?.targetRecord.id == record.id
        let isSourceInFlight = journeyOrganizerSourceInFlightID == record.id
        let isOrganizerSelected = isOrganizingMapJourneys
            && journeyOrganizerSelectedRecordID == record.id
        let isWiggling = isOrganizingMapJourneys && reduceMotion == false

        return ZStack {
            mapMarker(for: record)
                .opacity(isDropTarget ? 0 : 1)

            if isDropTarget, mergeOwnsReceiver == false {
                // When one memory is dropped on another, the target becomes
                // the same two-cell Folder receiver used by the rail. The
                // next object therefore appears exactly where the held token
                // will land rather than switching to a generic plus target.
                MapJourneyFolderReceiver(
                    targetRecord: record,
                    sourceRecord: nil
                )
                .shadow(color: Color.black.opacity(0.18), radius: 10, y: 5)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.92))
                )
            }

            if isOrganizerSelected {
                Circle()
                    .stroke(Color.white.opacity(0.94), lineWidth: 2)
                    .frame(width: 56, height: 56)
                    .shadow(color: Color.black.opacity(0.3), radius: 3)
                    .allowsHitTesting(false)
            }
        }
            .frame(
                width: JourneyFolderCoverLayout.size,
                height: JourneyFolderCoverLayout.size
            )
            .contentShape(Rectangle())
            .rotationEffect(isWiggling ? .degrees(mapJourneyWiggle(for: record.id) * 1.45) : .zero)
            .offset(y: isWiggling ? mapJourneyWiggle(for: record.id) * 0.9 : 0)
            .scaleEffect(isDropTarget && reduceMotion == false ? 1.02 : 1)
            // A Journey copies a memory into a private Folder. Leaving the
            // source partially visible makes that non-destructive meaning
            // clear while the lifted token is in the person's hand.
            .opacity(isSourceInFlight ? 0.68 : 1)
            .animation(
                isWiggling
                    ? .easeInOut(duration: 0.18)
                        .repeatForever(autoreverses: true)
                        .delay(mapJourneyWiggleDelay(for: record.id))
                    : .easeOut(duration: 0.16),
                value: isWiggling
            )
            .animation(organizerSettleAnimation, value: isDropTarget)
            .animation(.easeOut(duration: 0.16), value: isSourceInFlight)
            .animation(organizerLiftAnimation, value: isOrganizerSelected)
            .zIndex(isOrganizerSelected ? 1 : 0)
    }

    private func mapMarkerClusterTargetFrame(for cluster: MapMemoryHitCluster) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: JourneyOrganizerCoordinateSpace.space)
            Color.clear.preference(
                key: JourneyOrganizerTargetFramePreferenceKey.self,
                // Every member of a visual stack shares one physical handle.
                // Keeping their target frame identical makes it possible to
                // cycle the stack without ever moving its map coordinate.
                value: Dictionary(
                    uniqueKeysWithValues: cluster.records.map {
                        (.record($0.id), frame)
                    }
                )
            )
        }
    }

    private func mapJourneyWiggleDelay(for id: UUID) -> Double {
        Double(abs(id.uuidString.hashValue % 6)) * 0.018
    }

    /// Opens a memory in the already-mounted MyMap canvas. A list row is a
    /// quick, local preview: it should acknowledge the tap immediately, bring
    /// the place into view, and still leave enough surrounding map to orient
    /// the person before they choose to open the capsule.
    private func openRecordFromList(_ record: UserMapRecord) {
        isSearchFocused = false
        hasPresentedMap = true
        listFocusRecordID = record.isMapExperienceItem ? record.id : nil

        // The map is already mounted behind the List. Put it at the final
        // preview camera before revealing it, so this transition never shows
        // a marker travelling across the screen.
        if record.isMapExperienceItem {
            focusListPreview(on: record)
        }

        withAnimation(.easeOut(duration: 0.16)) {
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

        withAnimation(.easeOut(duration: 0.16)) {
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

    private var mapScopeAccessibilityValue: String {
        guard let journey = mapFocusedJourney else { return "All memories" }
        let isPrivateCollection = journeyFolders.contains { $0.id == journey.id }
        return isPrivateCollection ? "Collection: \(journey.title)" : "Journey: \(journey.title)"
    }

    /// A Journey replaces the archive controls with the same folder chrome
    /// used by MapTalk. Its child row, map pins and capsule all read from one
    /// `MapJourneyScope`, so they cannot drift into the general archive.
    @ViewBuilder
    private var mapJourneyControls: some View {
        if let journey = mapFocusedJourney {
            let journeyScope = scope(for: journey)
            let isPrivateFolder = journeyFolders.contains(where: { $0.id == journey.id })

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
                    },
                    subtitleForJourney: { pathJourney in
                        journeyFolders.contains(where: { $0.id == pathJourney.id })
                            ? "Collection"
                            : "Journey"
                    },
                    exitAccessibilityLabel: isPrivateFolder ? "Back to MyMap" : "Back",
                    exitAccessibilityIdentifier: isPrivateFolder
                        ? "mymap.map-folder-exit"
                        : "map-journey-exit"
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
            .accessibilityElement(children: .contain)
            .accessibilityLabel(isPrivateFolder ? "Collection: \(journey.title)" : "Journey")
            .accessibilityValue(isPrivateFolder ? "\(journeyScope.storyItems.count) memories" : "")
            .accessibilityIdentifier(
                isPrivateFolder
                    ? "mymap.map-folder-scope.\(journey.id.uuidString)"
                    : "mymap.journey-header"
            )
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
        if let folder = journeyFolders.first(where: { $0.id == journey.id }) {
            // The order inside a private folder is an authored decision. Do
            // not run it back through MapStoryFeed's chronological sorting.
            return MapJourneyScope(
                journey: privateMapJourney(for: folder),
                userProvider: userProvider,
                storyItems: folderStoryItems(for: folder)
            )
        }
        return MapJourneyScope(journey: journey, userProvider: userProvider)
    }

    /// A private JourneyFolder never becomes a public post. This is only the
    /// in-memory adapter used to enter the shared map scope, then discarded
    /// when the person returns to the root of MyMap.
    private func privateMapJourney(for folder: JourneyFolder) -> JourneyPost {
        let resolvedReels = folder.memberReferences.compactMap { reference -> RealPost? in
            guard case let .reel(id) = reference else { return nil }
            return reels.first(where: { $0.id == id })
        }
        let resolvedPOIs = folder.memberReferences.compactMap { reference -> RatedPOI? in
            guard case let .poi(id) = reference else { return nil }
            return footprints.first(where: { $0.id == id })?.ratedPOI
        }
        let coordinates = mapJourneyRecords(for: folder).map(\.coordinate)
        let coordinate: CLLocationCoordinate2D
        if coordinates.isEmpty {
            coordinate = currentMapRegion.center
        } else {
            coordinate = CLLocationCoordinate2D(
                latitude: coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count),
                longitude: coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
            )
        }

        return JourneyPost(
            id: folder.id,
            userId: folder.userId,
            title: folder.title,
            content: "",
            coordinate: coordinate,
            createdAt: folder.createdAt,
            reels: resolvedReels,
            pois: resolvedPOIs,
            likes: [],
            comments: []
        )
    }

    private func folderStoryItems(for folder: JourneyFolder) -> [RealStoriesRow.StoryItem] {
        folder.memberReferences.compactMap { reference in
            switch reference {
            case let .reel(id):
                guard let reel = reels.first(where: { $0.id == id }) else { return nil }
                return RealStoriesRow.StoryItem(real: reel)

            case let .poi(id):
                guard let footprint = footprints.first(where: { $0.id == id }) else { return nil }
                let group = MapStoryFeed.poiGroup(
                    for: footprint.ratedPOI,
                    onlyRecentStories: false,
                    userProvider: userProvider
                ) ?? RealStoriesRow.POIStoryGroup(
                    ratedPOI: footprint.ratedPOI,
                    sharers: [],
                    latestTimestamp: footprint.latestVisit ?? folder.updatedAt
                )
                return RealStoriesRow.StoryItem(poiGroup: group)
            }
        }
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
        let topInset: CGFloat
        if mapFocusedJourney != nil {
            topInset = MapJourneyCamera.journeyChromeInset
        } else if isListRecordFocusActive {
            // The preview only keeps the native back affordance. Do not
            // reserve room for search and filters that are deliberately gone.
            topInset = Self.listPreviewNavigationInset
        } else {
            topInset = archiveChromeInset
        }
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

    /// List entry is intentionally not a MapFlightController transition. That
    /// controller is right for browsing a world map, but its city clamp and
    /// staged long-distance motion make a single-record preview feel remote.
    /// This is a non-animated camera assignment while List still covers the
    /// canvas: the first visible map frame is already at the destination.
    private func focusListPreview(on record: UserMapRecord) {
        mapFlightController.cancelActiveTransition()

        let target = listPreviewRegion(for: record)
        let framedTarget = mapStoryViewport?.framed(target) ?? target

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            cameraPosition = .region(framedTarget)
            currentMapRegion = framedTarget
        }
    }

    /// These are semantic preview scales rather than a fitted world/city
    /// region. A POI retains its neighbourhood; a Reel has a little more
    /// context for its story radius. The compact capsule supplies the detail,
    /// so the map should never start at street-level or at city-scale.
    private func listPreviewRegion(for record: UserMapRecord) -> MKCoordinateRegion {
        switch record.kind {
        case let .poi(rated):
            return MKCoordinateRegion(
                center: rated.poi.coordinate,
                latitudinalMeters: 4_500,
                longitudinalMeters: 4_500
            )
        case let .reel(reel):
            let span = min(max(reel.radiusMeters * 8, 5_500), 8_000)
            return MKCoordinateRegion(
                center: reel.center,
                latitudinalMeters: span,
                longitudinalMeters: span
            )
        case .journey:
            return storyRegion(for: record)
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

    /// The held object must keep the exact identity it had on the map. A
    /// small lift is enough to say "picked up"; replacing an avatar with a
    /// photo card while it follows the finger breaks that physical continuity.
    @ViewBuilder
    private func liftedMapMarkerPreview(for record: UserMapRecord) -> some View {
        mapMarker(for: record)
            .frame(width: JourneyFolderCoverLayout.size, height: JourneyFolderCoverLayout.size)
            .scaleEffect(1.1)
            .shadow(color: Color.black.opacity(0.26), radius: 12, y: 7)
    }

    private static let mapCapsuleCompactFraction: CGFloat = 0.35
    private static let mapCapsuleCompactDetent = PresentationDetent.fraction(mapCapsuleCompactFraction)
    private static let listPreviewNavigationInset: CGFloat = 54

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

/// Once released, the map marker becomes a compact memory token only for the
/// final handoff into a Journey cover. While it is under the person's finger,
/// `liftedMapMarkerPreview` above keeps the original map marker intact.
private struct MapJourneyFolderTokenPreview: View {
    let record: UserMapRecord

    var body: some View {
        // The visual language changes only at the container boundary, where
        // a square memory genuinely belongs to the Folder mosaic.
        MemoryThumbnail(
            record: record,
            size: JourneyFolderCoverLayout.dragTokenSize,
            cornerRadius: 15,
            showsKindBadge: false
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
        }
        .scaleEffect(JourneyFolderCoverLayout.dragTokenLiftScale)
        .shadow(color: Color.black.opacity(0.24), radius: 12, y: 7)
    }
}

/// A Journey has no geographic coordinate, so move mode gives it a small
/// private-photo-folder treatment: the memories are the visual identity, not
/// another line of map UI chrome.
private struct MapJourneyFolderDockCover: View {
    let records: [UserMapRecord]
    let isDropTarget: Bool
    let appendAnimation: JourneyFolderAppendAnimation?
    let appendPhase: JourneyFolderAppendPhase?
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            coverBackground
            memoryMosaic
        }
        .frame(width: size, height: size)
        .clipShape(coverShape)
        .overlay {
            coverShape
                .stroke(
                    Color.black.opacity(
                        isDropTarget ? 0.3 : (appendPhase == .receiving ? 0.22 : 0.1)
                    ),
                    lineWidth: isDropTarget ? 1.35 : 1
                )
        }
    }

    private var coverShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
    }

    private var pocketAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.24, dampingFraction: 0.8)
    }

    private var pocketTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.78).combined(with: .opacity)
    }

    private var coverBackground: some View {
        coverShape.fill(Color(.secondarySystemBackground))
    }

    private var memoryMosaic: some View {
        ZStack {
            Group {
                if displayRecords.isEmpty {
                    Image(systemName: "folder.fill")
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                } else {
                    ForEach(Array(displayRecords.prefix(4).enumerated()), id: \.element.id) { index, record in
                        folderMemoryThumbnail(record, at: index)
                    }
                }
            }

            if isInsertionPocketVisible {
                openInsertionPocket
            }
        }
    }

    private var displayRecords: [UserMapRecord] {
        guard let appendAnimation else { return records }

        // Covers are newest-first. The incoming memory therefore occupies the
        // same top-left cell during landing and after the transient state is
        // gone; it never flashes in and vanishes from a full Folder.
        let existing = appendAnimation.previousRecords
            .filter { $0.id != appendAnimation.sourceRecord.id }
        return [appendAnimation.sourceRecord] + Array(existing.prefix(3))
    }

    private func folderMemoryThumbnail(
        _ record: UserMapRecord,
        at index: Int
    ) -> some View {
        let isIncoming = appendAnimation?.sourceRecord.id == record.id
        let yieldsForHoveredPocket = isDropTarget && appendAnimation == nil && index == insertionSlotIndex
        let hidesBehindLandingToken = isIncoming && appendPhase == .receiving
        return MemoryThumbnail(
            record: record,
            size: size * 0.54,
            cornerRadius: size * 0.15,
            showsKindBadge: false
        )
        .offset(thumbnailOffset(for: index))
        .scaleEffect(yieldsForHoveredPocket && reduceMotion == false ? 0.9 : 1)
        .opacity(hidesBehindLandingToken ? 0 : (yieldsForHoveredPocket ? 0.16 : 1))
        .animation(
            pocketAnimation,
            value: isDropTarget
        )
        .animation(
            pocketAnimation,
            value: appendPhase
        )
    }

    private var insertionSlotIndex: Int {
        0
    }

    private func thumbnailOffset(for index: Int) -> CGSize {
        JourneyFolderCoverLayout.slotOffset(for: index)
    }

    private var isInsertionPocketVisible: Bool {
        (isDropTarget && appendAnimation == nil) || appendPhase == .receiving
    }

    /// While hovering, the Folder keeps its photos visible and makes one
    /// pocket available. The recess is deliberately photographic and quiet —
    /// it should feel like a real slot in a small album, not an upload target.
    private var openInsertionPocket: some View {
        RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
            .fill(Color.black.opacity(0.1))
            .frame(width: size * 0.54, height: size * 0.54)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
                    .stroke(Color.white.opacity(0.46), lineWidth: 1)
            }
            .offset(thumbnailOffset(for: insertionSlotIndex))
            .transition(pocketTransition)
            .animation(pocketAnimation, value: isInsertionPocketVisible)
    }

}

/// The on-map receiver and the travelling Folder share the exact same visual
/// geometry. That makes the transformation legible: the target opens into a
/// container, the held memory fills its open cell, then the very same object
/// is filed in the Journey rail.
private struct MapJourneyFolderReceiver: View {
    let targetRecord: UserMapRecord
    let sourceRecord: UserMapRecord?

    private let size = JourneyFolderCoverLayout.size

    var body: some View {
        ZStack {
            coverShape
                .fill(Color(.secondarySystemBackground))

            coverShape
                .stroke(Color.black.opacity(0.12), lineWidth: 1)

            folderMemory(targetRecord)
                .offset(JourneyFolderCoverLayout.slotOffset(for: 0))

            if let sourceRecord {
                folderMemory(sourceRecord)
                    .offset(JourneyFolderCoverLayout.slotOffset(for: 1))
            } else {
                insertionPocket
                    .offset(JourneyFolderCoverLayout.slotOffset(for: 1))
            }
        }
        .frame(width: size, height: size)
    }

    private var coverShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
    }

    private var insertionPocket: some View {
        RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
            .fill(Color.black.opacity(0.1))
            .frame(
                width: JourneyFolderCoverLayout.thumbnailSize,
                height: JourneyFolderCoverLayout.thumbnailSize
            )
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                    .stroke(Color.white.opacity(0.46), lineWidth: 1)
            }
    }

    private func folderMemory(_ record: UserMapRecord) -> some View {
        MemoryThumbnail(
            record: record,
            size: JourneyFolderCoverLayout.thumbnailSize,
            cornerRadius: size * 0.15,
            showsKindBadge: false
        )
    }
}

/// A temporary, physical-looking Folder at the map target. It is intentionally
/// separate from the rail tile: first the two memories become a container,
/// then that completed container is filed away in the private shelf.
private struct MapJourneyFolderMergeContainer: View {
    let sourceRecord: UserMapRecord
    let targetRecord: UserMapRecord
    let showsSourceInside: Bool

    var body: some View {
        MapJourneyFolderReceiver(
            targetRecord: targetRecord,
            sourceRecord: showsSourceInside ? sourceRecord : nil
        )
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: 5)
    }
}

/// A map-created Folder remains provisional at this step: the person can name
/// and keep it, or cancel the creation without leaving an Untitled folder
/// behind.
@MainActor
private struct JourneyFolderNamingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let folder: JourneyFolder
    let onSave: (JourneyFolder) -> Void
    let onCancel: (JourneyFolder) -> Void

    @State private var title = ""
    @State private var didResolve = false
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
                    Text("Name your collection")
                        .font(.title3.weight(.bold))

                    Text(folder.memberReferences.count == 1
                         ? "Private collection · 1 memory"
                         : "Private collection · \(folder.memberReferences.count) memories")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            TextField("Untitled Collection", text: $title)
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
                Button("Cancel") {
                    cancelCreation()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color(.secondarySystemBackground), in: Capsule(style: .continuous))
                .accessibilityIdentifier("mymap.cancel-journey-creation")

                Button(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Create collection" : "Save name") {
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
        .onDisappear {
            // Pulling the sheet down has the same meaning as Cancel. A
            // provisional folder must never survive a dismissed name step.
            if didResolve == false {
                didResolve = true
                onCancel(folder)
            }
        }
    }

    private func save() {
        var renamedFolder = folder
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        renamedFolder.title = cleanTitle.isEmpty ? folder.title : cleanTitle
        didResolve = true
        onSave(renamedFolder)
        dismiss()
    }

    private func cancelCreation() {
        didResolve = true
        onCancel(folder)
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
        let distance = current.distance(from: CLLocation(latitude: nearest.1.latitude, longitude: nearest.1.longitude))
        return distance <= 50_000 ? nearest.0 : "Unknown location"
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

struct UserMapRecordCard: View {
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
                    .foregroundStyle(Color.secondary.opacity(0.65))
                    .lineLimit(2)
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
        MapImage(url: url) { phase in
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
