import AVFoundation
import AVKit
import CoreLocation
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The consumer-facing creation actions. A Place is evidence from a real
/// location; a Reel is a short thought from that same location.
enum MapTalkPublishDestination: Identifiable, Hashable {
    case place
    case reel

    var id: Self { self }
}

/// A POI has no separate authored caption. Optional photo text is rendered
/// into its media before this draft is handed to the durable publishing queue.
struct MapTalkPlaceDraft {
    enum Target {
        case existing(RatedPOI)
        case new(name: String, category: POICategory)
    }

    let target: Target
    let media: RatedPOI.Media?
}

enum MapTalkReelBubbleSource: Hashable {
    /// Memories are kept in the order the person selected them. This is a
    /// publish-time source; the final Reel owns an independent Bubble snapshot.
    case memories([JourneyFolder.MemberReference])
    /// A Folder is a shortcut for selecting its current contents. Publishing a
    /// Reel must never add the Reel back into that private Folder.
    case folder(UUID)
}

struct MapTalkReelDraft {
    let text: String
    /// Ordered media is the Reel's story. The first item is its cover, which
    /// existing map and timeline surfaces already use as their preview.
    let attachments: [RealPost.Attachment]
    let bubbleSource: MapTalkReelBubbleSource?
}

enum MapTalkPublishDraft {
    case place(MapTalkPlaceDraft)
    case reel(MapTalkReelDraft)
}

private struct BubbleDateSection: Identifiable {
    let title: String
    let records: [UserMapRecord]

    var id: String { title }
}

private struct ReelMediaDeleteTargetFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.isEmpty == false {
            value = next
        }
    }
}

/// One recognizer owns the entire hold → drag → release lifecycle. Keeping it
/// continuous prevents a surrounding ScrollView from cancelling the cleanup
/// phase and leaving the temporary remove target visible.
@MainActor
private struct ReelMediaPressDragGesture: UIGestureRecognizerRepresentable {
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.28
        recognizer.allowableMovement = 44
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        return recognizer
    }

    func updateUIGestureRecognizer(
        _ recognizer: UILongPressGestureRecognizer,
        context: Context
    ) {
        recognizer.minimumPressDuration = 0.28
        recognizer.allowableMovement = 44
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UILongPressGestureRecognizer,
        context: Context
    ) {
        switch recognizer.state {
        case .began:
            onBegan(recognizer.location(in: nil))
        case .changed:
            onChanged(recognizer.location(in: nil))
        case .ended:
            onEnded(recognizer.location(in: nil))
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }
}

/// A custom creation surface rather than a system form. Place keeps the map
/// as evidence; Reel becomes a content-first story composer. In both cases,
/// the coordinate is never editable: a post uses the device's live location
/// when it is finally saved.
struct MapTalkPublishComposer: View {
    private static let maximumReelAssets = 9

    private enum BubblePickerTab: String, CaseIterable, Identifiable {
        case memories = "Memories"
        case folders = "Folders"

        var id: Self { self }
    }

    @Environment(\.appEnv) private var appEnvironment
    private var isConnected: Bool { appEnvironment.backend != nil }
    private var isHosted: Bool { appEnvironment.backend?.api.baseURL.scheme == "https" }
    private var publicAudienceTitle: String { isHosted ? "Test members" : "Public" }
    let destination: MapTalkPublishDestination
    let nearbyPlaces: [MapTalkNearbyPlaceOption]
    let isLoadingNearbyPlaces: Bool
    let nearbyPlaceIssue: POISearchIssue?
    let folders: [JourneyFolder]
    let myMapRecords: [UserMapRecord]
    let currentUserID: UUID
    let userProvider: (UUID) -> User?
    let hasLiveLocation: Bool
    let locationAuthorization: CLAuthorizationStatus
    let onCancel: () -> Void
    /// Keep the draft alive until it is saved to the durable local outbox.
    /// A stable request ID lets a retry resolve the same submission.
    let onPublish: (MapTalkPublishDraft, MapPublishAudience, UUID) async throws -> Void
    let onSearchNearbyPlaces: (String) async -> MapTalkNearbyPlaceSearchResult
    let onRetryNearbyPlaces: () -> Void

    @State private var mediaPickerItem: PhotosPickerItem?
    @State private var selectedMedia: ComposerMediaAsset?
    @State private var placePhotoText = PhotoTextOverlay()
    @State private var editedPlacePhoto: ComposerMediaAsset?
    @State private var isShowingPhotoTextEditor = false
    @State private var isLoadingMedia = false
    @State private var mediaImportToken = UUID()
    @State private var mediaImportTask: Task<Void, Never>?
    @State private var pendingMediaItem: PhotosPickerItem?
    @State private var pendingVideoURL: URL?
    @State private var pendingVideoPlayer: AVPlayer?
    @State private var mediaImportIssue: String?
    @State private var pendingVideoDuration: Double = 0
    @State private var pendingVideoStart: Double = 0
    @State private var pendingClipRange: CMTimeRange?
    @State private var videoClipStart: Double = 0
    @State private var isChoosingVideoClip = false
    @State private var isRetakingPlace = false
    @State private var isConfirmingDiscard = false
    @State private var placeVideoPlayer: AVPlayer?
    @State private var isPlaceCameraBusy = false
    @State private var isShowingPlaceLibrary = false
    @State private var placeAudience: MapPublishAudience = .privateMyMap
    @State private var isShowingNearbyPlaceChoices = false
    @State private var isShowingNewPlaceEditor = false
    /// The nearby directory may refresh as location accuracy improves. Freeze
    /// the visible order while the person is choosing so rows never jump
    /// beneath their finger.
    @State private var nearbyPlaceChoiceSnapshot: [MapTalkNearbyPlaceOption] = []
    @State private var nearbyPlaceSearchText = ""
    @State private var nearbyPlaceSearchResults: [MapTalkNearbyPlaceOption] = []
    @State private var nearbyResultsQuery = ""
    @State private var nearbyPlaceSearchIssue: POISearchIssue?
    @State private var nearbySearchRetry = 0
    @State private var isSearchingPlaces = false
    /// Keep the person's choice independent from live search results. Nearby
    /// results can refresh while the composer is open; that must not silently
    /// clear a landmark they already confirmed.
    @State private var selectedNearbyPlaceOption: MapTalkNearbyPlaceOption?
    @State private var isCreatingLandmark = false
    @State private var didChooseLandmarkManually = false
    @State private var landmarkName = ""
    @State private var landmarkCategory: POICategory = .other
    @State private var newLandmarkNameDraft = ""
    @State private var newLandmarkCategoryDraft: POICategory = .other
    @State private var reelText = ""
    @State private var reelPickerItems: [PhotosPickerItem] = []
    @State private var reelAssets: [ComposerMediaAsset] = []
    @State private var previewedReelVideo: ComposerVideoPreview?
    @State private var reelIsImporting = false
    @State private var reelImportToken = UUID()
    @State private var reelAudience: MapPublishAudience = .livePublic
    @State private var isShowingAudienceChoices = false
    @State private var selectedBubbleSource: MapTalkReelBubbleSource?
    @State private var pendingBubbleSource: MapTalkReelBubbleSource?
    @State private var isShowingBubblePicker = false
    @State private var bubblePickerTab: BubblePickerTab = .memories
    @State private var bubbleSearchText = ""
    @State private var submissionIssue: String?
    @State private var isSubmitting = false
    @State private var hasUnconfirmedSubmission = false
    @State private var submissionRequestID = UUID()
    @State private var bubblePreviewID = UUID()
    @State private var reelPreviewCreatedAt = Date.now
    @State private var draggedReelAssetID: UUID?
    @State private var draggedReelAssetOrigin: CGPoint?
    @State private var draggedReelAssetTranslation: CGSize = .zero
    @State private var reelMediaDeleteTargetFrame: CGRect = .zero
    @State private var isReelMediaDeleteTargeted = false
    @FocusState private var isTextFocused: Bool
    @FocusState private var isPlaceSearchFocused: Bool
    @Namespace private var bubbleTabNamespace

    private var selectedNearbyPOI: RatedPOI? {
        selectedNearbyPlaceOption?.place
    }

    private var trimmedReelText: String {
        reelText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedLandmarkName: String {
        landmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNewLandmarkNameDraft: String {
        newLandmarkNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var presentedNearbyPlaces: [MapTalkNearbyPlaceOption] {
        let options = nearbyPlaceChoiceSnapshot.isEmpty ? nearbyPlaces : nearbyPlaceChoiceSnapshot
        guard !nearbyPlaceSearchQuery.isEmpty else { return options }
        let local = options.filter { $0.place.poi.name.localizedStandardContains(nearbyPlaceSearchQuery) }
        var seen = Set<UUID>()
        return (local + nearbyPlaceSearchResults).filter { seen.insert($0.id).inserted }
    }

    private var nearbyPlaceSearchQuery: String {
        nearbyPlaceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct NearbyPlaceSearchRequest: Equatable {
        let query: String
        let isVisible: Bool
        let hasLiveLocation: Bool
        let nearbyPlaceIDs: [UUID]
        let retry: Int
    }

    private var nearbyPlaceSearchRequest: NearbyPlaceSearchRequest {
        .init(query: nearbyPlaceSearchQuery,
              isVisible: isShowingNearbyPlaceChoices && !isShowingNewPlaceEditor,
              hasLiveLocation: hasLiveLocation,
              nearbyPlaceIDs: nearbyPlaces.map(\.id), retry: nearbySearchRetry)
    }

    private var remainingReelAssetCapacity: Int {
        max(0, Self.maximumReelAssets - reelAssets.count)
    }

    private var canSubmit: Bool {
        guard isSubmitting == false,
              isLoadingMedia == false,
              isPlaceCameraBusy == false,
              reelIsImporting == false,
              mediaPickerItem == nil,
              pendingMediaItem == nil, pendingVideoURL == nil,
              !isRetakingPlace,
              reelPickerItems.isEmpty,
              draggedReelAssetID == nil else { return false }
        switch destination {
        case .place:
            return selectedNearbyPOI != nil || (isCreatingLandmark && trimmedLandmarkName.isEmpty == false)
        case .reel:
            return trimmedReelText.isEmpty == false || reelAssets.isEmpty == false
                || normalizedBubbleSource(selectedBubbleSource) != nil
        }
    }

    private var locationAccessIsDenied: Bool {
        locationAuthorization == .denied || locationAuthorization == .restricted
    }

    private var locationStatusText: String {
        if hasLiveLocation { return "Current location" }
        return locationAccessIsDenied ? "Location off" : "Finding location…"
    }

    var body: some View {
        Group {
            switch destination {
            case .place:
                placeComposer
            case .reel:
                ZStack {
                    reelComposer
                        .allowsHitTesting(isShowingBubblePicker == false)
                        .accessibilityHidden(isShowingBubblePicker)

                    if isShowingBubblePicker {
                        bubblePicker
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeOut(duration: 0.18), value: isShowingBubblePicker)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbarVisibility(.hidden, for: .tabBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maptalk.publish-composer")
        .disabled(isSubmitting)
        .allowsHitTesting(isSubmitting == false)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            configureInitialSelection()
        }
        .onDisappear {
            placeVideoPlayer?.pause()
            pendingVideoPlayer?.pause()
        }
        .onChange(of: nearbyPlaces.map(\.id)) { _, _ in
            if isShowingNearbyPlaceChoices {
                // Preserve rows under a finger, but don't freeze away newly
                // discovered places when location or directory results improve.
                let latest = Dictionary(nearbyPlaces.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                let previousIDs = Set(nearbyPlaceChoiceSnapshot.map(\.id))
                nearbyPlaceChoiceSnapshot = nearbyPlaceChoiceSnapshot.compactMap { latest[$0.id] }
                    + nearbyPlaces.filter { !previousIDs.contains($0.id) }
            }
            synchronizeNearbySelection()
        }
        .task(id: nearbyPlaceSearchRequest) {
            let request = nearbyPlaceSearchRequest
            if nearbyResultsQuery != request.query {
                nearbyPlaceSearchResults = []
                nearbyResultsQuery = request.query
            }
            nearbyPlaceSearchIssue = nil
            guard request.isVisible, request.hasLiveLocation, !request.query.isEmpty else {
                isSearchingPlaces = false
                return
            }
            isSearchingPlaces = true
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            let results = await onSearchNearbyPlaces(request.query)
            guard !Task.isCancelled, nearbyPlaceSearchRequest == request else { return }
            if results.issue == nil || !results.options.isEmpty {
                nearbyPlaceSearchResults = results.options
            }
            nearbyPlaceSearchIssue = results.issue
            isSearchingPlaces = false
        }
        .onChange(of: hasLiveLocation) { _, isReady in
            guard isReady, submissionIssue == "Finding your location. Try again in a moment." else { return }
            submissionIssue = nil
        }
        .onChange(of: mediaPickerItem) { _, item in
            guard let item, isSubmitting == false else { return }
            clearPendingMedia()
            pendingMediaItem = item
            mediaPickerItem = nil
            startPlaceImport()
        }
        .onChange(of: reelPickerItems) { _, items in
            guard items.isEmpty == false, isSubmitting == false else { return }
            let token = UUID()
            reelImportToken = token
            reelIsImporting = true
            Task {
                await importReelMedia(items, token: token)
            }
        }
        .photosPicker(
            isPresented: $isShowingPlaceLibrary,
            selection: $mediaPickerItem,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        )
        .sheet(item: $previewedReelVideo) { video in
            ComposerVideoPlayer(url: video.url)
        }
        .alert("Discard this post?", isPresented: $isConfirmingDiscard) {
            Button("Discard", role: .destructive, action: discardComposer)
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text("Your unsaved changes will be lost.")
        }
    }

    private var placeComposer: some View {
        ZStack {
            placeCaptureStep
                .opacity(isShowingNearbyPlaceChoices || isShowingPhotoTextEditor || isChoosingVideoClip ? 0 : 1)
                .disabled(isShowingNearbyPlaceChoices || isShowingPhotoTextEditor || isChoosingVideoClip)
                .accessibilityHidden(isShowingNearbyPlaceChoices || isShowingPhotoTextEditor || isChoosingVideoClip)
            if isShowingNearbyPlaceChoices {
                placePickerStep
                    .transition(.move(edge: .trailing))
            }
            if isShowingPhotoTextEditor, case let .photo(_, _, image) = selectedMedia {
                MapTalkPhotoTextEditor(image: image, draft: placePhotoText, embedded: true,
                    onCancel: { isShowingPhotoTextEditor = false }, onDone: applyPlacePhotoText)
            }
            if isChoosingVideoClip {
                placeVideoClipEditor
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
        .clipped()
        .animation(.easeOut(duration: 0.20), value: isShowingNearbyPlaceChoices)
    }

    private var placeCaptureStep: some View {
        VStack(spacing: 0) {
            placeHeader

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    placeMediaSection
                        .padding(.horizontal, 16)
                        .padding(.top, 10)

                    placeDetails
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .disabled(isPlaceCameraBusy)

                    if let submissionIssue {
                        Text(submissionIssue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.red.opacity(0.82))
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                }
                .frame(maxWidth: .infinity)
                .disabled(hasUnconfirmedSubmission)
                .padding(.bottom, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollDisabled(isPlaceCameraBusy)

            placeSubmitButton
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .padding(.top, 6)
    }

    private var placePickerStep: some View {
        ZStack {
            if isShowingNewPlaceEditor {
                newPlaceEditorPage
                    .transition(.move(edge: .trailing))
            } else {
                nearbyPlacePickerPage
                    .transition(.move(edge: .leading))
            }
        }
        .clipped()
        .background(Color.white)
        .animation(.easeOut(duration: 0.20), value: isShowingNewPlaceEditor)
    }

    private var nearbyPlacePickerPage: some View {
        VStack(spacing: 0) {
            placePickerHeader(
                title: "Choose a place",
                backLabel: "Back to place",
                backAction: dismissNearbyPlaceChoices
            )

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.black.opacity(0.4))
                TextField("Search nearby places", text: $nearbyPlaceSearchText)
                    .font(.system(size: 15))
                    .foregroundStyle(.black)
                    .focused($isPlaceSearchFocused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { isPlaceSearchFocused = false }
                    .accessibilityIdentifier("maptalk.place.search")
                if isSearchingPlaces {
                    ProgressView().controlSize(.small).tint(.gray)
                }
                if !nearbyPlaceSearchText.isEmpty {
                    Button { nearbyPlaceSearchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.gray)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear place search")
                }
            }
            .padding(12)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            ScrollView(showsIndicators: false) {
                nearbyPlaceChoices
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 0) {
                placePickerDivider
                createPlaceButton
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .background(Color.white)
        }
        .padding(.top, 6)
        .background(Color.white)
    }

    private var newPlaceEditorPage: some View {
        VStack(spacing: 0) {
            placePickerHeader(
                title: "New place",
                backLabel: "Back to nearby places",
                backAction: dismissNewPlaceEditor
            )

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Name")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.48))

                    TextField("Name this place", text: $newLandmarkNameDraft)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.black)
                        .focused($isTextFocused)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit {
                            if trimmedNewLandmarkNameDraft.isEmpty == false {
                                useNewPlace()
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .background(
                            Color.black.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .padding(.top, 8)
                        .accessibilityIdentifier("maptalk.place.new-name")

                    Text("Type")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.48))
                        .padding(.top, 24)

                    newPlaceCategoryGrid
                        .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)

            Button(action: useNewPlace) {
                Text("Use this place")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(ComposerPressStyle())
            .disabled(trimmedNewLandmarkNameDraft.isEmpty)
            .opacity(trimmedNewLandmarkNameDraft.isEmpty ? 0.22 : 1)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .accessibilityIdentifier("maptalk.place.use-new")
        }
        .padding(.top, 6)
        .background(Color.white)
    }

    private func placePickerHeader(
        title: String,
        backLabel: String,
        backAction: @escaping () -> Void
    ) -> some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)

            HStack {
                Button(action: backAction) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ComposerPressStyle())
                .accessibilityLabel(backLabel)
                .accessibilityIdentifier("maptalk.place.picker-back")

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    /// Expression comes first, then the ordered media layout and optional
    /// Bubble. The publishing surface stays white and quiet; only the content
    /// preview mirrors the layout that will appear in a Reel card.
    private var reelComposer: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            VStack(spacing: 0) {
                reelHeader

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        reelCaptionEditor
                        reelMediaSection
                            .padding(.top, 12)

                        Rectangle()
                            .fill(Color.black.opacity(0.09))
                            .frame(height: 1)
                            .padding(.top, 24)

                        reelFooterRows

                        if let submissionIssue {
                            Text(submissionIssue)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.red.opacity(0.82))
                                .padding(.top, 14)
                        }
                    }
                    .disabled(hasUnconfirmedSubmission)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 22)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollDisabled(draggedReelAssetID != nil)
            }
            .padding(.top, 6)
        }
    }

    private var reelHeader: some View {
        ZStack {
            Text("New reel")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)

            HStack {
                Button(action: cancelComposer) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.black)
                .buttonStyle(ComposerPressStyle())
                .accessibilityLabel("Cancel publishing")
                .accessibilityIdentifier("maptalk.publish.cancel")
                .disabled(isPlaceCameraBusy)

                Spacer()

                Button {
                    submit(reelAudience)
                } label: {
                    Group {
                        if isSubmitting {
                            ProgressView()
                                .tint(.black)
                        } else {
                            Text(reelAudience == .livePublic ? "Share" : "Save")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(canSubmit ? Color.black : Color.black.opacity(0.28))
                        }
                    }
                    .frame(minWidth: 56, minHeight: 40)
                }
                .buttonStyle(ComposerPressStyle())
                .disabled(canSubmit == false)
                .accessibilityIdentifier("maptalk.reel.publish")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    @ViewBuilder
    private var reelMediaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            reelMediaPreview
                .transition(.opacity.combined(with: .scale(scale: 0.985)))

            if draggedReelAssetID != nil {
                reelMediaDeleteTarget
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            if let bubble = reelPreviewBubble {
                reelBubblePreview(bubble)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: normalizedBubbleSource(selectedBubbleSource))
        .animation(.easeOut(duration: 0.14), value: draggedReelAssetID)
        .onPreferenceChange(ReelMediaDeleteTargetFramePreferenceKey.self) { frame in
            reelMediaDeleteTargetFrame = frame
        }
    }

    @ViewBuilder
    private var reelMediaPreview: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            spacing: 8
        ) {
            ForEach(reelAssets) { asset in
                reelMediaGridCell(asset)
            }

            if remainingReelAssetCapacity > 0 {
                reelAddMediaGridTile
                    .opacity(draggedReelAssetID == nil ? 1 : 0)
                    .allowsHitTesting(draggedReelAssetID == nil)
                    .accessibilityHidden(draggedReelAssetID != nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reel media preview, \(reelAssets.count) items")
        .accessibilityIdentifier("maptalk.reel.media-preview")
    }

    /// The grid owns each cell's geometry. Media only paints inside that
    /// square, so portrait and landscape assets cannot change row sizing or
    /// overlap neighbouring cells.
    @ViewBuilder
    private func reelMediaGridCell(_ asset: ComposerMediaAsset) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    reelPreviewAsset(
                        asset,
                        cornerRadius: 14,
                        size: proxy.size
                    )
                }
            }
            .zIndex(draggedReelAssetID == asset.id ? 20 : 0)
    }

    private func reelPreviewAsset(
        _ asset: ComposerMediaAsset,
        cornerRadius: CGFloat,
        size: CGSize
    ) -> some View {
        let isDragged = draggedReelAssetID == asset.id

        return ReelAssetVisual(asset: asset)
            // Establish the tile boundary before clipping. The drag transform
            // is applied later, so the whole clipped square can still move.
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .center) {
                if asset.isVideo {
                    reelPreviewPlayBadge
                }
            }
            .overlay {
                reelPreviewBorder(cornerRadius: cornerRadius)
            }
            .scaleEffect(isDragged ? 1.035 : 1)
            .opacity(isDragged ? 0.92 : 1)
            .offset(isDragged ? draggedReelAssetTranslation : .zero)
            .zIndex(isDragged ? 20 : 0)
            .shadow(
                color: isDragged ? Color.black.opacity(0.20) : .clear,
                radius: isDragged ? 16 : 0,
                y: isDragged ? 8 : 0
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onTapGesture {
                guard case let .video(_, url, _) = asset, draggedReelAssetID == nil else { return }
                isTextFocused = false
                previewedReelVideo = .init(url: url)
            }
            .gesture(
                ReelMediaPressDragGesture(
                    onBegan: { location in
                        beginReelMediaDrag(asset.id, at: location)
                    },
                    onChanged: { location in
                        updateReelMediaDrag(asset.id, at: location)
                    },
                    onEnded: { location in
                        finishReelMediaDrag(
                            asset.id,
                            delete: reelMediaDeleteTargetFrame.insetBy(dx: -12, dy: -12)
                                .contains(location)
                        )
                    },
                    onCancelled: {
                        finishReelMediaDrag(asset.id, delete: false)
                    }
                )
            )
            .accessibilityLabel(asset.isVideo ? "Video" : "Photo")
            .accessibilityHint(asset.isVideo
                ? "Tap to preview. Hold and drag to the remove area"
                : "Hold and drag to the remove area")
            .accessibilityAction(named: "Remove") {
                removeReelAsset(asset.id)
            }
            .accessibilityIdentifier("maptalk.reel.media-item.\(asset.id.uuidString)")
    }

    private var reelPreviewPlayBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 34, height: 34)
            .background(.white.opacity(0.92), in: Circle())
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }

    private func reelPreviewBorder(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(Color.black.opacity(0.07), lineWidth: 1)
            .allowsHitTesting(false)
    }

    private func reelBubblePreview(_ bubble: JourneyPost) -> some View {
        HStack(spacing: -9) {
            ForEach(Array(reelBubbleRecords(for: bubble).prefix(4))) { record in
                MemoryThumbnail(
                    record: record,
                    size: 34,
                    cornerRadius: 9,
                    showsKindBadge: false
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white, lineWidth: 2)
                }
            }

            if reelBubbleRecords(for: bubble).count > 4 {
                Text("+\(reelBubbleRecords(for: bubble).count - 4)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.52))
                    .padding(.leading, 14)
            }

            Spacer(minLength: 10)

            Text(selectedBubbleSummary)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.46))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.055), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bubble preview, \(selectedBubbleSummary)")
        .accessibilityIdentifier("maptalk.reel.bubble-preview")
    }

    private func reelBubbleRecords(for bubble: JourneyPost) -> [UserMapRecord] {
        bubble.orderedMemberReferences.compactMap(record(for:))
    }

    private var reelAddMediaGridTile: some View {
        PhotosPicker(
            selection: $reelPickerItems,
            maxSelectionCount: remainingReelAssetCapacity,
            selectionBehavior: .ordered,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        ) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    reelAddMediaVisual
                }
        }
        .buttonStyle(ComposerPressStyle())
        .disabled(reelIsImporting)
        .accessibilityLabel(reelAssets.isEmpty ? "Add photos or videos" : "Add more photos or videos")
        .accessibilityHint("Up to \(Self.maximumReelAssets) items. Videos up to 60 seconds")
        .accessibilityIdentifier("maptalk.reel.add-media")
    }

    private var reelAddMediaVisual: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(0.04))

            if reelIsImporting {
                ProgressView()
                    .tint(.black)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.black.opacity(0.62))
            }
        }
    }

    private var reelMediaDeleteTarget: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: 14, weight: .semibold))
            Text("Remove")
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(isReelMediaDeleteTargeted ? Color.white : Color.red)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(
            isReelMediaDeleteTargeted ? Color.red : Color.red.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.red.opacity(isReelMediaDeleteTargeted ? 0 : 0.16), lineWidth: 1)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReelMediaDeleteTargetFramePreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        }
        .scaleEffect(isReelMediaDeleteTargeted ? 1.015 : 1)
        .accessibilityLabel("Remove media drop area")
        .accessibilityIdentifier("maptalk.reel.media-delete-target")
    }

    private func beginReelMediaDrag(_ id: UUID, at location: CGPoint) {
        guard isSubmitting == false, hasUnconfirmedSubmission == false else { return }
        guard draggedReelAssetID == nil || draggedReelAssetID == id else { return }
        if draggedReelAssetID == nil {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        draggedReelAssetID = id
        draggedReelAssetOrigin = location
        draggedReelAssetTranslation = .zero
    }

    private func updateReelMediaDrag(_ id: UUID, at location: CGPoint) {
        guard draggedReelAssetID == id, let origin = draggedReelAssetOrigin else { return }
        draggedReelAssetTranslation = CGSize(
            width: location.x - origin.x,
            height: location.y - origin.y
        )
        let isTargeted = reelMediaDeleteTargetFrame.insetBy(dx: -12, dy: -12).contains(location)
        if isTargeted != isReelMediaDeleteTargeted {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        isReelMediaDeleteTargeted = isTargeted
    }

    private func finishReelMediaDrag(_ id: UUID, delete: Bool) {
        // Let UIKit finish dispatching the recognizer event before SwiftUI
        // changes or removes the view that owns that recognizer.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                draggedReelAssetID = nil
                draggedReelAssetOrigin = nil
                draggedReelAssetTranslation = .zero
                isReelMediaDeleteTargeted = false
            }

            if delete {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                removeReelAsset(id)
            }
        }
    }

    private var reelCaptionEditor: some View {
        ZStack(alignment: .topLeading) {
            if reelText.isEmpty {
                Text("Write a caption…")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.black.opacity(0.30))
                    .padding(.top, 8)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $reelText)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.black)
                .focused($isTextFocused)
                .scrollContentBackground(.hidden)
                .background(.clear)
                .frame(height: 96, alignment: .topLeading)
                .accessibilityIdentifier("maptalk.reel.text")
        }
    }

    private var reelFooterRows: some View {
        VStack(spacing: 0) {
            bubbleSelector
            reelRowDivider

            reelSettingRow(
                title: "Location",
                value: locationStatusText,
                trailingSymbol: hasLiveLocation ? "checkmark" : nil
            )
            .accessibilityIdentifier("maptalk.publish-live-location")

            reelRowDivider

            Button {
                isTextFocused = false
                withAnimation(.easeOut(duration: 0.16)) {
                    isShowingAudienceChoices.toggle()
                }
            } label: {
                reelSettingRow(
                    title: "Who can see",
                    value: reelAudience == .livePublic ? publicAudienceTitle : "Only me",
                    showsChevron: true
                )
            }
            .buttonStyle(ComposerPressStyle())
            .accessibilityIdentifier("maptalk.reel.audience")

            if isShowingAudienceChoices {
                VStack(spacing: 0) {
                    reelRowDivider
                    reelAudienceChoice(.livePublic, title: publicAudienceTitle)
                    reelRowDivider
                    reelAudienceChoice(.privateMyMap, title: "Only me")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if isHosted && reelAudience == .livePublic {
                Text("Visible to invited test members as soon as you publish.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
            }
        }
    }

    private func reelAudienceChoice(
        _ audience: MapPublishAudience,
        title: String
    ) -> some View {
        Button {
            reelAudience = audience
            withAnimation(.easeOut(duration: 0.14)) {
                isShowingAudienceChoices = false
            }
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.black)

                Spacer(minLength: 0)

                if reelAudience == audience {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                }
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(ComposerPressStyle())
    }

    private func reelSettingRow(
        title: String,
        value: String? = nil,
        trailingSymbol: String? = nil,
        showsChevron: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.black)

            Spacer(minLength: 12)

            if let value {
                Text(value)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.black.opacity(0.46))
                    .lineLimit(1)
            }

            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.48))
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.28))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .contentShape(Rectangle())
    }

    private var reelRowDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.085))
            .frame(height: 1)
    }

    private var placeHeader: some View {
        ZStack {
            Text("Place")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)

            HStack {
                Button(action: cancelComposer) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ComposerPressStyle())
                .accessibilityLabel("Cancel publishing")
                .accessibilityIdentifier("maptalk.publish.cancel")

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private var placeMediaSection: some View {
        placeMediaStage
    }

    private var placeMediaStage: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                // Keep one capture session alive while choosing a landmark,
                // reviewing media or adding text. Only its running state changes.
                MapTalkInlineCameraView(
                        isActive: (selectedMedia == nil || isRetakingPlace)
                            && pendingMediaItem == nil && pendingVideoURL == nil
                            && !isLoadingMedia && !isShowingPlaceLibrary
                            && !isShowingNearbyPlaceChoices && !isSubmitting
                            && !isShowingPhotoTextEditor && !isChoosingVideoClip
                            && !hasUnconfirmedSubmission,
                        onCapture: importPlaceCameraCapture,
                        onOpenLibrary: presentPlaceLibrary,
                        onIssue: { submissionIssue = $0 },
                        onCaptureActivityChanged: { isPlaceCameraBusy = $0 }
                    )
                    .opacity(selectedMedia == nil || isRetakingPlace ? 1 : 0)
                    .disabled((selectedMedia != nil && !isRetakingPlace)
                        || pendingMediaItem != nil || pendingVideoURL != nil || isLoadingMedia)
                    .accessibilityHidden((selectedMedia != nil && !isRetakingPlace)
                        || pendingMediaItem != nil || pendingVideoURL != nil)
                if selectedMedia != nil && !isRetakingPlace {
                    placeMediaVisual
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()

                    VStack {
                        Spacer(minLength: 0)
                        HStack(spacing: 20) {
                            Button(action: presentPlaceCapture) {
                                Text("Retake")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(ComposerPressStyle())
                            .accessibilityIdentifier("maptalk.place.retake")

                            Spacer(minLength: 0)

                            if selectedMedia?.isVideo == false {
                                Button {
                                    guard !isLoadingMedia, !hasUnconfirmedSubmission,
                                          pendingMediaItem == nil, pendingVideoURL == nil else { return }
                                    isShowingPhotoTextEditor = true
                                } label: {
                                    Text("Aa")
                                        .font(.system(size: 20, weight: .semibold))
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(ComposerPressStyle())
                                .accessibilityLabel("Add text to photo")
                                .accessibilityValue(placePhotoText.text)
                                .accessibilityIdentifier("maptalk.place.photo-text")
                            }

                            Button(action: presentPlaceLibrary) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 19, weight: .medium))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(ComposerPressStyle())
                            .accessibilityLabel("Choose from library")
                            .accessibilityIdentifier("maptalk.place.library")
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .background {
                            LinearGradient(colors: [.clear, .black.opacity(0.65)],
                                           startPoint: .top, endPoint: .bottom)
                                .padding(.top, -32)
                        }
                    }
                }

                if isRetakingPlace {
                    VStack {
                        HStack {
                            Spacer()
                            Button("Cancel retake") {
                                clearPendingMedia()
                                isRetakingPlace = false
                            }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.black.opacity(0.45), in: Capsule())
                                .disabled(isPlaceCameraBusy)
                                .accessibilityIdentifier("maptalk.place.cancel-retake")
                        }
                        Spacer()
                    }
                    .padding(10)
                }

                VStack {
                    HStack {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(hasLiveLocation ? Theme.neonPrimary : Color.white.opacity(0.72))
                                .frame(width: 6, height: 6)
                            Text(hasLiveLocation ? "Current location" : (locationAccessIsDenied ? "Location off" : "Locating"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.28), in: Capsule())
                        .accessibilityLabel("Uses your live location")
                        .accessibilityIdentifier("maptalk.publish-live-location")
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)

                if !isChoosingVideoClip && (pendingMediaItem != nil || pendingVideoURL != nil) {
                    pendingPlaceMediaPreview
                } else if isLoadingMedia {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 326)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var placeMediaVisual: some View {
        switch editedPlacePhoto ?? selectedMedia {
        case let .photo(_, _, preview):
            Image(uiImage: preview)
                .resizable()
                .scaledToFit()
        case let .video(_, _, preview):
            if let placeVideoPlayer {
                VideoPlayer(player: placeVideoPlayer)
                    .accessibilityLabel("Video preview")
            } else if let preview {
                Image(uiImage: preview.image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.black
            }
        case nil:
            LinearGradient(
                colors: [Color.black.opacity(0.94), Color.black.opacity(0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var pendingPlaceMediaPreview: some View {
        ZStack {
            Color.black
            if let pendingVideoPlayer {
                VideoPlayer(player: pendingVideoPlayer)
                    .accessibilityLabel("Selected video preview")
            }
            VStack {
                HStack {
                    Spacer()
                    Button {
                        clearPendingMedia()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("Cancel adding media")
                    .accessibilityIdentifier("maptalk.place.import.cancel")
                }
                Spacer()
                VStack(spacing: 10) {
                    if isLoadingMedia {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text(pendingVideoURL == nil ? "Opening selection…" : "Preparing video…")
                                .font(.system(size: 14, weight: .medium))
                        }
                    } else if let mediaImportIssue {
                        Text(mediaImportIssue)
                            .font(.system(size: 14, weight: .medium))
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("maptalk.place.import.issue")
                        HStack(spacing: 24) {
                            Button("Try again") { startPlaceImport() }
                                .accessibilityIdentifier("maptalk.place.import.retry")
                            Button("Choose another") {
                                clearPendingMedia()
                                presentPlaceLibrary()
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minHeight: 44)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(12)
            .foregroundStyle(.white)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maptalk.place.import.preview")
    }

    private var placeVideoClipEditor: some View {
        VStack(spacing: 18) {
            HStack {
                Button("Cancel") { clearPendingMedia() }
                    .accessibilityIdentifier("maptalk.place.clip.cancel")
                Spacer()
                Text("Choose a clip").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Use clip") {
                    isChoosingVideoClip = false
                    pendingVideoPlayer?.pause()
                    startPlaceImport(timeRange: CMTimeRange(
                        start: CMTime(seconds: videoClipStart, preferredTimescale: 600),
                        duration: CMTime(seconds: min(60, pendingVideoDuration - videoClipStart), preferredTimescale: 600)))
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("maptalk.place.clip.use")
            }
            .font(.system(size: 15))
            .frame(height: 46)

            if let pendingVideoPlayer {
                VideoPlayer(player: pendingVideoPlayer)
                    .frame(maxHeight: 326)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            Text("Choose the 60 seconds you want to share.")
                .font(.system(size: 15, weight: .medium))
            Slider(value: $videoClipStart, in: pendingVideoStart...max(pendingVideoStart + 0.01, pendingVideoDuration - 60)) { editing in
                if !editing {
                    pendingVideoPlayer?.seek(to: CMTime(seconds: videoClipStart, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
                    pendingVideoPlayer?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: videoClipStart + 60, preferredTimescale: 600)
                }
            }
            .tint(.black)
            .accessibilityLabel("Clip start")
            .accessibilityIdentifier("maptalk.place.clip.start")
            Text("\(Int(videoClipStart))s – \(Int(min(pendingVideoDuration, videoClipStart + 60)))s")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Text("Your original video stays unchanged.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .background(.white)
        .foregroundStyle(.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maptalk.place.clip-editor")
    }

    private var placeDetails: some View {
        VStack(spacing: 0) {
            placeLandmarkSection

            placeRowDivider

            placeAudienceSelector
        }
    }

    @ViewBuilder
    private var placeLandmarkSection: some View {
        VStack(spacing: 0) {
            Button(action: toggleNearbyPlaceChoices) {
                placeSettingRow(
                    title: "Place",
                    value: selectedNearbyPOI?.poi.name
                        ?? (isCreatingLandmark ? trimmedLandmarkName : "Choose a place"),
                    showsChevron: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Place")
            .accessibilityValue(
                selectedNearbyPOI?.poi.name
                    ?? (isCreatingLandmark ? trimmedLandmarkName : "Not selected")
            )
            .accessibilityHint("Opens nearby place selection")
            .accessibilityIdentifier("maptalk.place.choose-landmark")
        }
    }

    private var nearbyPlaceChoices: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(nearbyPlaceSearchQuery.isEmpty ? "Nearby places" : "Search results")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.48))

                Spacer(minLength: 0)
            }
            .frame(height: 42)

            placePickerDivider

            if (nearbyPlaceSearchQuery.isEmpty ? nearbyPlaceIssue : nearbyPlaceSearchIssue) != nil,
               !isSearchingPlaces, !isLoadingNearbyPlaces {
                HStack(spacing: 12) {
                    Text("Places couldn't refresh.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Try again") {
                        if nearbyPlaceSearchQuery.isEmpty {
                            onRetryNearbyPlaces()
                        } else {
                            nearbySearchRetry += 1
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("maptalk.place.search.retry")
                }
                .frame(minHeight: 56)
            }

            if presentedNearbyPlaces.isEmpty,
               (nearbyPlaceSearchQuery.isEmpty ? nearbyPlaceIssue : nearbyPlaceSearchIssue) == nil {
                VStack(spacing: 10) {
                    if isLoadingNearbyPlaces, !isSearchingPlaces,
                       nearbyPlaceSearchQuery.isEmpty || !hasLiveLocation {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    } else if !isSearchingPlaces {
                        Image(systemName: "mappin.slash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.38))
                    }

                    Text(nearbyPlaceSearchQuery.isEmpty || !hasLiveLocation ? emptyNearbyPlacesMessage
                        : (isSearchingPlaces ? "Searching nearby…" : "No matching place nearby"))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.black.opacity(0.52))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(presentedNearbyPlaces.enumerated()), id: \.element.id) { index, option in
                        if index > 0 {
                            placePickerDivider
                        }
                        nearbyPlaceChoice(option)
                    }
                }
            }
        }
    }

    private var createPlaceButton: some View {
        Button(action: beginCreatingPlace) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 18)

                Text(isCreatingLandmark ? "Edit custom place" : "Create new place")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.black)

                Spacer(minLength: 0)
            }
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("maptalk.place.create-new")
    }

    private func nearbyPlaceChoice(_ option: MapTalkNearbyPlaceOption) -> some View {
        let isSelected = selectedNearbyPlaceOption?.id == option.id
        return Button {
            selectNearbyPlace(option)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.place.poi.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)

                    Text(nearbyPlaceSummary(option))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.black.opacity(0.46))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.place.poi.name)
        .accessibilityValue("\(nearbyPlaceContext(option)), \(Int(option.distanceMeters.rounded())) meters\(isSelected ? ", selected" : "")")
        .accessibilityIdentifier("maptalk.place.option.\(option.id.uuidString)")
    }

    private func nearbyPlaceSummary(_ option: MapTalkNearbyPlaceOption) -> String {
        let compactContext = nearbyPlaceContext(option)
            .components(separatedBy: " · ")
            .prefix(2)
            .joined(separator: " · ")
        return "\(Int(option.distanceMeters.rounded())) m · \(compactContext)"
    }

    private func nearbyPlaceContext(_ option: MapTalkNearbyPlaceOption) -> String {
        var context: [String] = []
        let friendCount = option.friendUsers.count

        if friendCount > 0 {
            context.append("\(friendCount) \(friendCount == 1 ? "friend" : "friends")")
        }
        if option.publicVisitorCount > 0 {
            context.append("\(option.publicVisitorCount) checked in")
        }
        if option.isInMyMap {
            context.append("In MyMap")
        }
        if context.isEmpty {
            context.append(option.place.poi.directoryKind == .airport ? "Airport" : option.place.poi.category.displayName)
        }

        return context.joined(separator: " · ")
    }

    private var newPlaceCategoryGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
            spacing: 8
        ) {
            ForEach(POICategory.allCases, id: \.rawValue) { category in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    newLandmarkCategoryDraft = category
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: category.symbolName)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 18)

                        Text(category.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(newLandmarkCategoryDraft == category ? Color.white : Color.black)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        newLandmarkCategoryDraft == category ? Color.black : Color.black.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityValue(newLandmarkCategoryDraft == category ? "Selected" : "")
                .accessibilityIdentifier("maptalk.place.new-category.\(category.rawValue)")
            }
        }
    }

    private var placeAudienceSelector: some View {
        placeAudienceMenu
    }

    private var placeAudienceMenu: some View {
        HStack(spacing: 12) {
            Text("Who can see")
                .font(.system(size: 15))
                .foregroundStyle(.black)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                placeAudienceChoice(.privateMyMap, title: "Only me")
                placeAudienceChoice(.livePublic, title: publicAudienceTitle)
            }
            .padding(3)
            .background(Color.black.opacity(0.045), in: Capsule())
        }
        .frame(minHeight: 62)
    }

    private func placeAudienceChoice(_ audience: MapPublishAudience, title: String) -> some View {
        Button {
            placeAudience = audience
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(placeAudience == audience ? .white : .black)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(placeAudience == audience ? Color.black : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(placeAudience == audience ? "Selected" : "")
        .accessibilityIdentifier(audience == .livePublic ? "maptalk.place.audience.public" : "maptalk.place.audience.private")
    }

    private func placeSettingRow(
        title: String,
        value: String,
        showsChevron: Bool = false,
        chevronName: String = "chevron.right"
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.black)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.black.opacity(0.46))
                .lineLimit(1)

            if showsChevron {
                Image(systemName: chevronName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.28))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .contentShape(Rectangle())
    }

    private var placeRowDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.085))
            .frame(height: 1)
    }

    private var placePickerDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.085))
            .frame(height: 0.5)
    }

    private var placeSubmitButton: some View {
        Button {
            submit(placeAudience)
        } label: {
            Group {
                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(placeAudience == .livePublic ? "Post" : "Add to MyMap")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(ComposerPressStyle())
        .disabled(canSubmit == false)
        .opacity(canSubmit || isSubmitting ? 1 : 0.22)
        .accessibilityIdentifier("maptalk.place.publish")
        .accessibilityHint(selectedMedia == nil ? "Save a check-in without a photo or video" : "")
    }

    private var emptyNearbyPlacesMessage: String {
        if locationAccessIsDenied {
            return "Location unavailable"
        }
        if hasLiveLocation == false || isLoadingNearbyPlaces {
            return "Finding nearby places…"
        }
        return "No places found nearby"
    }

    private var bubbleSelector: some View {
        Button(action: openBubblePicker) {
            reelSettingRow(
                title: "Bubble",
                value: selectedBubbleSummary,
                showsChevron: true
            )
        }
        .buttonStyle(ComposerPressStyle())
        .accessibilityIdentifier("maptalk.reel.choose-bubble")
    }

    private var selectedBubbleSummary: String {
        switch normalizedBubbleSource(selectedBubbleSource) {
        case let .memories(references):
            return references.count == 1 ? "1 memory" : "\(references.count) memories"
        case let .folder(folderID):
            return folders.first(where: { $0.id == folderID })?.title ?? "Folder"
        case nil:
            return "Add"
        }
    }

    /// Mirrors the publication snapshot closely enough for the canonical Reel
    /// card to render the Bubble in its final position. This value is visual
    /// only: publishing still rebuilds and validates the snapshot in the view
    /// model against the archive's current contents.
    private var reelPreviewBubble: JourneyPost? {
        let source = normalizedBubbleSource(selectedBubbleSource)
        let references: [JourneyFolder.MemberReference]
        let title: String

        switch source {
        case let .memories(selected):
            references = selected
            title = "Bubble"
        case let .folder(folderID):
            guard let folder = folders.first(where: { $0.id == folderID }) else {
                return nil
            }
            references = availableReferences(in: folder)
            let trimmedTitle = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
            title = trimmedTitle.isEmpty ? "Bubble" : trimmedTitle
        case nil:
            return nil
        }

        var reels: [RealPost] = []
        var places: [RatedPOI] = []
        for reference in references {
            guard let record = record(for: reference) else { continue }
            switch record.kind {
            case let .reel(reel):
                var previewReel = reel
                previewReel.capsuleId = nil
                previewReel.likes = []
                previewReel.comments = []
                reels.append(previewReel)
            case let .poi(place):
                places.append(place)
            case .journey:
                continue
            }
        }

        guard reels.isEmpty == false || places.isEmpty == false else { return nil }
        return JourneyPost(
            id: bubblePreviewID,
            userId: currentUserID,
            title: title,
            content: "",
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            createdAt: reelPreviewCreatedAt,
            orderedMemberReferences: references,
            reels: reels,
            pois: places,
            likes: [],
            comments: []
        )
    }

    private var bubblePicker: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            VStack(spacing: 0) {
                bubblePickerHeader
                bubblePickerTabs

                if normalizedBubbleSource(pendingBubbleSource) != nil {
                    pendingBubbleSelectionBar
                }

                if bubblePickerTab == .memories {
                    bubbleSearchField
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                } else {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 12)
                }

                ScrollView(showsIndicators: false) {
                    if bubblePickerTab == .memories {
                        bubbleMemoryList
                    } else {
                        bubbleFolderList
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .padding(.top, 6)
        }
        .accessibilityIdentifier("maptalk.reel.bubble-picker")
    }

    private var bubblePickerHeader: some View {
        ZStack {
            Text("Add bubble")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.black)

            HStack {
                Button(action: discardBubblePickerChanges) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(.black)
                .buttonStyle(ComposerPressStyle())
                .accessibilityLabel("Back to reel")
                .accessibilityIdentifier("maptalk.reel.bubble-back")

                Spacer()

                Button(action: commitBubblePickerChanges) {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(minWidth: 56, minHeight: 44)
                }
                .buttonStyle(ComposerPressStyle())
                .accessibilityIdentifier("maptalk.reel.bubble-done")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private var bubblePickerTabs: some View {
        HStack(spacing: 28) {
            ForEach(BubblePickerTab.allCases) { tab in
                Button {
                    isTextFocused = false
                    withAnimation(.easeOut(duration: 0.14)) {
                        bubblePickerTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 15, weight: bubblePickerTab == tab ? .semibold : .regular))
                        .foregroundStyle(bubblePickerTab == tab ? Color.black : Color.black.opacity(0.42))
                        .padding(.vertical, 12)
                        .overlay(alignment: .bottom) {
                            if bubblePickerTab == tab {
                                Capsule()
                                    .fill(Color.black)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "bubble-tab", in: bubbleTabNamespace)
                            }
                        }
                }
                .buttonStyle(ComposerPressStyle())
                .accessibilityIdentifier("maptalk.reel.bubble-tab.\(tab.rawValue.lowercased())")
                .accessibilityValue(bubblePickerTab == tab ? "Selected" : "")
                .accessibilityAddTraits(bubblePickerTab == tab ? .isSelected : [])
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var pendingBubbleSelectionBar: some View {
        HStack(spacing: 12) {
            Text(pendingBubbleSummary)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.56))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    pendingBubbleSource = nil
                }
            } label: {
                Text("Clear")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(minHeight: 36)
            }
            .buttonStyle(ComposerPressStyle())
            .accessibilityLabel("Remove bubble selection")
            .accessibilityIdentifier("maptalk.reel.bubble-clear")
        }
        .padding(.horizontal, 20)
        .frame(height: 38)
        .background(Color.black.opacity(0.025))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var pendingBubbleSummary: String {
        switch normalizedBubbleSource(pendingBubbleSource) {
        case let .memories(references):
            return references.count == 1 ? "1 memory selected" : "\(references.count) memories selected"
        case let .folder(folderID):
            guard let folder = folders.first(where: { $0.id == folderID }) else {
                return "Folder unavailable"
            }
            return "\(folder.title) selected"
        case nil:
            return ""
        }
    }

    private var bubbleSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.black.opacity(0.38))

            TextField("Search MyMap", text: $bubbleSearchText)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.black)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isTextFocused)

            if bubbleSearchText.isEmpty == false {
                Button {
                    bubbleSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.black.opacity(0.25))
                }
                .buttonStyle(ComposerPressStyle())
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("maptalk.reel.bubble-search")
    }

    @ViewBuilder
    private var bubbleMemoryList: some View {
        let sections = groupedBubbleRecords
        if sections.isEmpty {
            bubbleEmptyState(
                title: bubbleSearchText.isEmpty ? "Your MyMap is empty" : "No memories found",
                subtitle: bubbleSearchText.isEmpty ? "Save a Place or Reel first." : "Try another search."
            )
        } else {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.title) { section in
                    Section {
                        ForEach(section.records) { record in
                            bubbleMemoryRow(record)
                            if record.id != section.records.last?.id {
                                reelRowDivider
                                    .padding(.leading, 66)
                            }
                        }
                    } header: {
                        BubbleDateHeader(
                            title: section.title,
                            count: section.records.count,
                            date: section.records.first?.timestamp ?? .now
                        )
                        .accessibilityIdentifier("maptalk.reel.bubble-date-section.\(section.id)")
                    }
                    if section.id != sections.last?.id {
                        Color.clear.frame(height: 6)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private var bubbleFolderList: some View {
        if folders.isEmpty {
            bubbleEmptyState(
                title: "No folders yet",
                subtitle: "Create one in MyMap, then choose it here."
            )
        } else {
            LazyVStack(spacing: 0) {
                ForEach(folders) { folder in
                    bubbleFolderRow(
                        folder,
                        records: folder.memberReferences.compactMap { bubbleRecordLookup[$0] }
                    )
                    if folder.id != folders.last?.id {
                        reelRowDivider
                            .padding(.leading, 92)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private func bubbleMemoryRow(_ record: UserMapRecord) -> some View {
        let reference = bubbleReference(for: record)
        let order = reference.flatMap(bubbleSelectionOrder(for:))

        return Button {
            guard let reference else { return }
            toggleBubbleMemory(reference)
        } label: {
            HStack(spacing: 12) {
                MemoryThumbnail(record: record, size: 54, cornerRadius: 8)

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(bubbleMetadata(for: record))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.black.opacity(0.42))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                bubbleSelectionMark(order: order, isSelected: order != nil)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(ComposerPressStyle())
        .accessibilityLabel("\(record.title), \(order.map { "selected \($0)" } ?? "not selected")")
        .accessibilityIdentifier("maptalk.reel.bubble-memory.\(record.id.uuidString)")
    }

    private func bubbleFolderRow(
        _ folder: JourneyFolder,
        records: [UserMapRecord]
    ) -> some View {
        let references = records.compactMap { bubbleReference(for: $0) }
        let isAvailable = references.isEmpty == false
        let isSelected: Bool = {
            guard case let .folder(selectedID) = pendingBubbleSource else { return false }
            return selectedID == folder.id
        }()

        return Button {
            guard isAvailable else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                pendingBubbleSource = isSelected ? nil : .folder(folder.id)
            }
        } label: {
            HStack(spacing: 14) {
                bubbleFolderCover(records: records)

                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)

                    Text(references.count == 1 ? "1 memory" : "\(references.count) memories")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.black.opacity(0.42))
                }

                Spacer(minLength: 8)
                bubbleSelectionMark(order: nil, isSelected: isSelected)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .opacity(isAvailable ? 1 : 0.36)
        }
        .buttonStyle(ComposerPressStyle())
        .disabled(isAvailable == false)
        .accessibilityLabel("\(folder.title), \(references.count) memories")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier("maptalk.reel.bubble-folder.\(folder.id.uuidString)")
    }

    private func bubbleSelectionMark(order: Int?, isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.black : Color.clear)
            Circle()
                .stroke(isSelected ? Color.black : Color.black.opacity(0.22), lineWidth: 1.25)

            if let order {
                Text("\(order)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private func bubbleFolderCover(records: [UserMapRecord]) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.045))

            if records.isEmpty {
                Image(systemName: "folder")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(Color.black.opacity(0.28))
            } else if records.count == 1, let record = records.first {
                MemoryThumbnail(record: record, size: 58, cornerRadius: 10, showsKindBadge: false)
            } else {
                ForEach(Array(records.prefix(4).enumerated()), id: \.offset) { index, record in
                    MemoryThumbnail(record: record, size: 27, cornerRadius: 5, showsKindBadge: false)
                        .offset(
                            x: index.isMultiple(of: 2) ? -14 : 14,
                            y: index < 2 ? -14 : 14
                        )
                }
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.07), lineWidth: 1)
        }
    }

    private func bubbleEmptyState(title: String, subtitle: String) -> some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.black)
            Text(subtitle)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.black.opacity(0.42))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 72)
        .padding(.horizontal, 24)
    }

    private var filteredBubbleRecords: [UserMapRecord] {
        let query = bubbleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return myMapRecords }
        return myMapRecords.filter { record in
            record.title.localizedCaseInsensitiveContains(query)
                || bubbleMetadata(for: record).localizedCaseInsensitiveContains(query)
        }
    }

    private var groupedBubbleRecords: [BubbleDateSection] {
        Dictionary(grouping: filteredBubbleRecords, by: bubbleDateSectionTitle(for:))
            .map { title, records in
                BubbleDateSection(
                    title: title,
                    records: records.sorted { $0.timestamp > $1.timestamp }
                )
            }
            .sorted { lhs, rhs in
                (lhs.records.first?.timestamp ?? .distantPast)
                    > (rhs.records.first?.timestamp ?? .distantPast)
            }
    }

    private func bubbleDateSectionTitle(for record: UserMapRecord) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(record.timestamp) { return "Today" }
        if calendar.isDate(record.timestamp, equalTo: .now, toGranularity: .weekOfYear) {
            return "This Week"
        }
        return record.timestamp.formatted(.dateTime.month(.wide).year())
    }

    private func bubbleMetadata(for record: UserMapRecord) -> String {
        switch record.kind {
        case let .poi(rated):
            return "Place · \(rated.poi.category.displayName) · \(record.cityName)"
        case .reel:
            return "Reel · \(record.cityName)"
        case .journey:
            return "Bubble"
        }
    }

    private func bubbleReference(for record: UserMapRecord) -> JourneyFolder.MemberReference? {
        switch record.kind {
        case .poi:
            return .poi(record.id)
        case .reel:
            return .reel(record.id)
        case .journey:
            return nil
        }
    }

    private func record(for reference: JourneyFolder.MemberReference) -> UserMapRecord? {
        myMapRecords.first { bubbleReference(for: $0) == reference }
    }

    private var bubbleRecordLookup: [JourneyFolder.MemberReference: UserMapRecord] {
        myMapRecords.reduce(into: [:]) { result, record in
            guard let reference = bubbleReference(for: record) else { return }
            result[reference] = record
        }
    }

    private func availableReferences(in folder: JourneyFolder) -> [JourneyFolder.MemberReference] {
        let available = Set(bubbleRecordLookup.keys)
        return folder.memberReferences.filter(available.contains)
    }

    private func bubbleSelectionOrder(for reference: JourneyFolder.MemberReference) -> Int? {
        let references: [JourneyFolder.MemberReference]
        switch pendingBubbleSource {
        case let .memories(selected):
            references = selected
        case let .folder(folderID):
            references = folders.first(where: { $0.id == folderID })
                .map(availableReferences(in:)) ?? []
        case nil:
            references = []
        }
        guard let index = references.firstIndex(of: reference) else {
            return nil
        }
        return index + 1
    }

    private func normalizedBubbleSource(
        _ source: MapTalkReelBubbleSource?
    ) -> MapTalkReelBubbleSource? {
        switch source {
        case let .memories(references):
            let available = references.reduce(into: [JourneyFolder.MemberReference]()) { result, reference in
                guard record(for: reference) != nil,
                      result.contains(reference) == false else {
                    return
                }
                result.append(reference)
            }
            return available.isEmpty ? nil : .memories(available)

        case let .folder(folderID):
            guard let folder = folders.first(where: { $0.id == folderID }),
                  availableReferences(in: folder).isEmpty == false else {
                return nil
            }
            return .folder(folderID)

        case nil:
            return nil
        }
    }

    private func toggleBubbleMemory(_ reference: JourneyFolder.MemberReference) {
        var references: [JourneyFolder.MemberReference]
        switch normalizedBubbleSource(pendingBubbleSource) {
        case let .memories(current):
            references = current
        case let .folder(folderID):
            references = folders.first(where: { $0.id == folderID })
                .map(availableReferences(in:)) ?? []
        case nil:
            references = []
        }

        if let index = references.firstIndex(of: reference) {
            references.remove(at: index)
        } else {
            references.append(reference)
        }
        withAnimation(.easeOut(duration: 0.14)) {
            pendingBubbleSource = references.isEmpty ? nil : .memories(references)
        }
    }

    private func openBubblePicker() {
        isTextFocused = false
        isShowingAudienceChoices = false
        pendingBubbleSource = normalizedBubbleSource(selectedBubbleSource)
        bubbleSearchText = ""
        switch pendingBubbleSource {
        case .folder:
            bubblePickerTab = .folders
        case .memories, nil:
            bubblePickerTab = .memories
        }
        withAnimation(.easeOut(duration: 0.18)) {
            isShowingBubblePicker = true
        }
    }

    private func discardBubblePickerChanges() {
        isTextFocused = false
        pendingBubbleSource = selectedBubbleSource
        withAnimation(.easeOut(duration: 0.18)) {
            isShowingBubblePicker = false
        }
    }

    private func commitBubblePickerChanges() {
        isTextFocused = false
        let normalized = normalizedBubbleSource(pendingBubbleSource)
        pendingBubbleSource = normalized
        selectedBubbleSource = normalized
        withAnimation(.easeOut(duration: 0.18)) {
            isShowingBubblePicker = false
        }
    }

    private func configureInitialSelection() {
        guard destination == .place else { return }
        synchronizeNearbySelection()
    }

    private func toggleNearbyPlaceChoices() {
        placeVideoPlayer?.pause()
        isTextFocused = false
        isPlaceSearchFocused = false
        nearbyPlaceChoiceSnapshot = nearbyPlaces
        nearbyPlaceSearchText = ""
        nearbyPlaceSearchResults = []
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isShowingNewPlaceEditor = false
        }
        withAnimation(.easeOut(duration: 0.16)) {
            isShowingNearbyPlaceChoices = true
        }
    }

    private func dismissNearbyPlaceChoices() {
        isPlaceSearchFocused = false
        withAnimation(.easeOut(duration: 0.14)) {
            isShowingNearbyPlaceChoices = false
        }
    }

    private func selectNearbyPlace(_ option: MapTalkNearbyPlaceOption) {
        UISelectionFeedbackGenerator().selectionChanged()
        isTextFocused = false
        isPlaceSearchFocused = false
        withAnimation(.easeOut(duration: 0.14)) {
            selectedNearbyPlaceOption = option
            isCreatingLandmark = false
            didChooseLandmarkManually = true
            landmarkName = ""
            newLandmarkNameDraft = ""
            newLandmarkCategoryDraft = .other
            isShowingNearbyPlaceChoices = false
            isShowingNewPlaceEditor = false
        }
    }

    private func beginCreatingPlace() {
        UISelectionFeedbackGenerator().selectionChanged()
        isTextFocused = false
        isPlaceSearchFocused = false
        if isCreatingLandmark, newLandmarkNameDraft.isEmpty {
            newLandmarkNameDraft = landmarkName
            newLandmarkCategoryDraft = landmarkCategory
        }
        withAnimation(.easeOut(duration: 0.20)) {
            isShowingNewPlaceEditor = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard isShowingNearbyPlaceChoices, isShowingNewPlaceEditor else { return }
            isTextFocused = true
        }
    }

    private func dismissNewPlaceEditor() {
        isTextFocused = false
        withAnimation(.easeOut(duration: 0.20)) {
            isShowingNewPlaceEditor = false
        }
    }

    private func useNewPlace() {
        guard trimmedNewLandmarkNameDraft.isEmpty == false else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        isTextFocused = false
        selectedNearbyPlaceOption = nil
        landmarkName = trimmedNewLandmarkNameDraft
        landmarkCategory = newLandmarkCategoryDraft
        isCreatingLandmark = true
        didChooseLandmarkManually = true
        submissionIssue = nil
        withAnimation(.easeOut(duration: 0.20)) {
            isShowingNearbyPlaceChoices = false
        }
    }

    private func synchronizeNearbySelection() {
        guard destination == .place, isCreatingLandmark == false,
              isSubmitting == false, hasUnconfirmedSubmission == false else { return }

        if let selectedNearbyPlaceOption,
           let refreshedOption = nearbyPlaces.first(where: { $0.id == selectedNearbyPlaceOption.id }) {
            self.selectedNearbyPlaceOption = refreshedOption
            return
        }

        // A manual selection remains valid even if a background directory
        // refresh briefly returns no rows. It is still proximity-validated by
        // the publishing boundary before anything is saved.
        if didChooseLandmarkManually {
            return
        }

        selectedNearbyPlaceOption = nil
    }

    private func presentPlaceCapture() {
        guard !isSubmitting, !hasUnconfirmedSubmission, !isLoadingMedia,
              pendingMediaItem == nil, pendingVideoURL == nil else { return }
        placeVideoPlayer?.pause()
        isRetakingPlace = true
        isTextFocused = false
        submissionIssue = nil
    }

    private func presentPlaceLibrary() {
        guard isSubmitting == false, hasUnconfirmedSubmission == false,
              isLoadingMedia == false, isPlaceCameraBusy == false,
              pendingMediaItem == nil, pendingVideoURL == nil else { return }
        placeVideoPlayer?.pause()
        isTextFocused = false
        submissionIssue = nil
        isShowingPlaceLibrary = true
    }

    private func importPlaceCameraCapture(_ result: MapTalkCameraCaptureResult) {
        let token = UUID()
        mediaImportToken = token
        isLoadingMedia = true

        switch result {
        case let .photo(image):
            let payload = SendableComposerImage(image)
            Task { @MainActor in
                let imported = await Task.detached(priority: .userInitiated) {
                    guard let photo = try? PublishPhotoNormalizer.prepare(cameraImage: payload.image),
                          let url = try? MapTalkMediaStorage.persist(photo.jpegData, fileExtension: "jpg") else {
                        return nil as ImportedComposerPhoto?
                    }
                    return ImportedComposerPhoto(url: url, preview: photo.preview)
                }.value

                guard mediaImportToken == token else {
                    if let imported { try? FileManager.default.removeItem(at: imported.url) }
                    return
                }
                guard let imported else {
                    isLoadingMedia = false
                    submissionIssue = "Couldn't prepare this photo. Please try again."
                    return
                }
                replacePlaceMedia(with: .photo(id: UUID(), url: imported.url,
                    preview: UIImage(cgImage: imported.preview.image)))
                isLoadingMedia = false
            }

        case let .video(url):
            clearPendingMedia()
            pendingVideoURL = url
            pendingVideoPlayer = AVPlayer(url: url)
            startPlaceImport()
        }
    }

    private func submit(_ audience: MapPublishAudience) {
        guard canSubmit else { return }

        guard hasLiveLocation else {
            withAnimation(.easeOut(duration: 0.15)) {
                submissionIssue = locationAccessIsDenied
                    ? "Allow location access in Settings to publish here."
                    : "Finding your location. Try again in a moment."
            }
            return
        }

        let draft: MapTalkPublishDraft

        switch destination {
        case .place:
            let target: MapTalkPlaceDraft.Target
            if let existing = selectedNearbyPOI {
                target = .existing(existing)
            } else {
                guard isCreatingLandmark, trimmedLandmarkName.isEmpty == false else { return }
                target = .new(name: trimmedLandmarkName, category: landmarkCategory)
            }
            draft = .place(.init(target: target, media: (editedPlacePhoto ?? selectedMedia)?.ratedPOIMedia))

        case .reel:
            guard canSubmit else { return }
            draft = .reel(
                .init(
                    text: trimmedReelText,
                    attachments: Array(reelAssets.prefix(Self.maximumReelAssets)).map(\.reelAttachment),
                    bubbleSource: normalizedBubbleSource(selectedBubbleSource)
                )
            )
        }

        isSubmitting = true
        isTextFocused = false
        submissionIssue = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                try await onPublish(draft, audience, submissionRequestID)
                // The connected backend has durably copied these files into
                // its outbox. Demo records still refer to the originals.
                if isConnected {
                    placeVideoPlayer?.pause()
                    selectedMedia.map(discard)
                    editedPlacePhoto.map(discard)
                    reelAssets.forEach(discard)
                }
            } catch {
                // The captured photos and text remain in this composer. A
                // transport or validation failure is not a location failure.
                withAnimation(.easeOut(duration: 0.15)) {
                    if let error = error as? BackendClientError {
                        if case .publishPending = error {
                            hasUnconfirmedSubmission = true
                        } else if error.confirmsPublishRejection {
                            hasUnconfirmedSubmission = false
                        }
                    }
                    submissionIssue = error.localizedDescription
                }
            }
        }
    }

    private func removeReelAsset(_ id: UUID) {
        guard isSubmitting == false, hasUnconfirmedSubmission == false else { return }
        guard let removedIndex = reelAssets.firstIndex(where: { $0.id == id }) else {
            return
        }

        withAnimation(.easeOut(duration: 0.16)) {
            let removed = reelAssets.remove(at: removedIndex)
            discard(removed)
        }
    }

    private func cancelComposer() {
        guard !isSubmitting, !isPlaceCameraBusy else { return }
        if selectedMedia != nil || pendingMediaItem != nil || pendingVideoURL != nil || isLoadingMedia
            || !reelAssets.isEmpty || !trimmedReelText.isEmpty || didChooseLandmarkManually
            || !newLandmarkNameDraft.isEmpty || selectedBubbleSource != nil {
            isConfirmingDiscard = true
        } else {
            discardComposer()
        }
    }

    private func discardComposer() {
        guard !isSubmitting, !isPlaceCameraBusy else { return }
        clearPendingMedia()
        mediaImportToken = UUID()
        reelImportToken = UUID()
        placeVideoPlayer?.pause()
        selectedMedia.map(discard)
        editedPlacePhoto.map(discard)
        reelAssets.forEach(discard)
        onCancel()
    }

    private func replacePlaceMedia(with asset: ComposerMediaAsset) {
        placeVideoPlayer?.pause()
        if let selectedMedia, selectedMedia.id != asset.id {
            discard(selectedMedia)
        }
        resetPlacePhotoText()
        selectedMedia = asset
        isRetakingPlace = false
        submissionIssue = nil
        if case let .video(_, url, _) = asset {
            placeVideoPlayer = AVPlayer(url: url)
        } else {
            placeVideoPlayer = nil
        }
    }

    private func resetPlacePhotoText() {
        editedPlacePhoto.map(discard)
        editedPlacePhoto = nil
        placePhotoText = PhotoTextOverlay()
        isShowingPhotoTextEditor = false
    }

    private func applyPlacePhotoText(_ overlay: PhotoTextOverlay) {
        guard case let .photo(sourceID, sourceURL, _) = selectedMedia,
              !isLoadingMedia, !isSubmitting, !hasUnconfirmedSubmission else { return }
        isShowingPhotoTextEditor = false
        let overlay = PhotoTextOverlayRenderer.sanitized(overlay)
        guard !overlay.isEmpty else {
            resetPlacePhotoText()
            return
        }
        let token = UUID()
        mediaImportToken = token
        isLoadingMedia = true
        submissionIssue = nil
        Task { @MainActor in
            do {
                // Always render from the original app-owned photo. Editing or
                // clearing the words must never bake a second layer over them.
                let imported = try await Task.detached(priority: .userInitiated) {
                    guard let image = UIImage(contentsOfFile: sourceURL.path) else {
                        throw ComposerMediaImportError.unreadable
                    }
                    let rendered = try PhotoTextOverlayRenderer.render(image: image, overlay: overlay)
                    let photo = try PublishPhotoNormalizer.prepare(cameraImage: rendered)
                    let url = try MapTalkMediaStorage.persist(photo.jpegData, fileExtension: "jpg")
                    return ImportedComposerPhoto(url: url, preview: photo.preview)
                }.value
                guard mediaImportToken == token, selectedMedia?.id == sourceID else {
                    try? FileManager.default.removeItem(at: imported.url)
                    return
                }
                editedPlacePhoto.map(discard)
                editedPlacePhoto = .photo(id: UUID(), url: imported.url,
                    preview: UIImage(cgImage: imported.preview.image))
                placePhotoText = overlay
                isLoadingMedia = false
            } catch {
                guard mediaImportToken == token else { return }
                isLoadingMedia = false
                submissionIssue = "Couldn't save the text. Your original photo is still here; try again."
            }
        }
    }

    private func discard(_ asset: ComposerMediaAsset) {
        for url in asset.ownedURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func clearPendingMedia() {
        mediaImportToken = UUID()
        let previousTask = mediaImportTask
        previousTask?.cancel()
        mediaImportTask = nil
        let source = pendingVideoURL
        pendingVideoPlayer?.pause()
        pendingVideoPlayer = nil
        pendingVideoURL = nil
        pendingMediaItem = nil
        mediaImportIssue = nil
        isLoadingMedia = false
        isChoosingVideoClip = false
        pendingVideoDuration = 0
        pendingVideoStart = 0
        pendingClipRange = nil
        videoClipStart = 0
        // Don't delete a file while a cancelled reader is still using it.
        if let source {
            Task {
                await previousTask?.value
                try? FileManager.default.removeItem(at: source)
            }
        }
    }

    private func startPlaceImport(timeRange: CMTimeRange? = nil) {
        guard pendingMediaItem != nil || pendingVideoURL != nil else { return }
        let previousTask = mediaImportTask
        previousTask?.cancel()
        let token = UUID()
        mediaImportToken = token
        isLoadingMedia = true
        mediaImportIssue = nil
        submissionIssue = nil
        if let timeRange { pendingClipRange = timeRange }
        let range = pendingClipRange
        mediaImportTask = Task {
            await previousTask?.value
            guard !Task.isCancelled, mediaImportToken == token else { return }
            await importPlaceSelection(token: token, timeRange: range)
        }
    }

    private func importPlaceSelection(token: UUID, timeRange: CMTimeRange?) async {
        guard mediaImportToken == token, !Task.isCancelled else { return }
        do {
            let item = pendingMediaItem
            let isVideo = pendingVideoURL != nil || item?.supportedContentTypes.contains {
                $0.conforms(to: .movie) || $0.conforms(to: .video)
            } == true
            let asset: ComposerMediaAsset
            if isVideo {
                if pendingVideoURL == nil, let item {
                    guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                        throw ComposerMediaImportError.unreadable
                    }
                    guard mediaImportToken == token, !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: movie.url)
                        return
                    }
                    pendingVideoURL = movie.url
                    pendingVideoPlayer = AVPlayer(url: movie.url)
                }
                guard let source = pendingVideoURL else { throw ComposerMediaImportError.unreadable }
                let sourceAsset = AVURLAsset(url: source)
                defer { withExtendedLifetime(sourceAsset) {} }
                guard let track = try await sourceAsset.loadTracks(withMediaType: .video).first else {
                    throw ComposerMediaImportError.unreadable
                }
                let range = try await track.load(.timeRange)
                guard mediaImportToken == token, !Task.isCancelled else { return }
                guard range.isValid, range.start.seconds.isFinite, range.end.seconds.isFinite,
                      range.duration.seconds.isFinite, range.duration.seconds > 0 else {
                    throw ComposerMediaImportError.unreadable
                }
                if range.duration.seconds > PublishVideoNormalizer.maximumDuration + 0.001, timeRange == nil {
                    pendingVideoDuration = range.end.seconds
                    pendingVideoStart = max(0, range.start.seconds)
                    videoClipStart = max(0, range.start.seconds)
                    pendingVideoPlayer?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: videoClipStart + 60, preferredTimescale: 600)
                    isLoadingMedia = false
                    isChoosingVideoClip = true
                    return
                }
                let prepared = try await PublishVideoNormalizer.prepare(sourceURL: source, timeRange: timeRange)
                let preview = try? await makeVideoPreview(for: prepared)
                asset = .video(id: UUID(), url: prepared, preview: preview)
            } else if let item {
                asset = try await loadComposerAsset(from: item)
            } else {
                throw ComposerMediaImportError.unreadable
            }
            guard mediaImportToken == token, !Task.isCancelled else {
                discard(asset)
                return
            }
            replacePlaceMedia(with: asset)
            clearPendingMedia()
        } catch {
            guard mediaImportToken == token, !Task.isCancelled else { return }
            isLoadingMedia = false
            if let issue = error as? PublishVideoNormalizer.ImportError {
                mediaImportIssue = issue.localizedDescription
            } else {
                mediaImportIssue = "Couldn't add this selection yet. Try again, or choose another."
            }
            // Keep the original local file or Photos selection for an explicit
            // retry; keep the previous composer photo/video until success.
        }
    }

    private func importReelMedia(_ items: [PhotosPickerItem], token: UUID) async {
        let importLimit = min(items.count, remainingReelAssetCapacity)
        guard importLimit > 0 else {
            await MainActor.run {
                guard reelImportToken == token else { return }
                reelPickerItems = []
                reelIsImporting = false
            }
            return
        }

        await MainActor.run {
            guard reelImportToken == token else { return }
            reelIsImporting = true
        }

        var imported: [ComposerMediaAsset] = []
        var firstImportIssue: String?
        for item in items.prefix(importLimit) {
            guard reelImportToken == token else {
                imported.forEach(discard)
                return
            }
            do {
                let asset = try await loadComposerAsset(from: item)
                imported.append(asset)
            } catch {
                if firstImportIssue == nil { firstImportIssue = error.localizedDescription }
            }
        }

        await MainActor.run {
            guard reelImportToken == token else {
                imported.forEach(discard)
                return
            }
            let capacity = max(0, Self.maximumReelAssets - reelAssets.count)
            let accepted = Array(imported.prefix(capacity))
            imported.dropFirst(capacity).forEach(discard)
            reelAssets.append(contentsOf: accepted)
            reelPickerItems = []
            reelIsImporting = false
            submissionIssue = imported.count < importLimit
                ? (firstImportIssue ?? "Some photos or videos couldn't be opened. Please try again.")
                : nil
        }
    }

    private func loadComposerAsset(from item: PhotosPickerItem) async throws -> ComposerMediaAsset {
        let supportedTypes = item.supportedContentTypes
        let isVideo = supportedTypes.contains { type in
            type.conforms(to: .movie) || type.conforms(to: .video)
        }

        if isVideo {
            guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                throw ComposerMediaImportError.unreadable
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            // Keep validation outside Photos' transfer wrapper so a long clip
            // gives the person an actionable error, not "import failed".
            let prepared = try await PublishVideoNormalizer.prepare(sourceURL: movie.url)
            let preview = try? await makeVideoPreview(for: prepared)
            return .video(id: UUID(), url: prepared, preview: preview)
        }

        if let photo = try await item.loadTransferable(type: ImportedComposerPhoto.self) {
            return .photo(id: UUID(), url: photo.url, preview: UIImage(cgImage: photo.preview.image))
        }

        throw ComposerMediaImportError.unreadable
    }
}

private enum ComposerMediaImportError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "Couldn't open this photo or video. Please choose it again."
    }
}

private struct ComposerVideoPreview: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ComposerVideoPlayer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .background(.black)
                .accessibilityIdentifier("maptalk.reel.video-preview")
                .navigationTitle("Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .tint(.primary)
                            .accessibilityIdentifier("maptalk.reel.video-preview.done")
                    }
                }
                .onAppear { player.play() }
                .onDisappear { player.pause() }
        }
    }
}

private enum ComposerMediaAsset: Identifiable {
    case photo(id: UUID, url: URL, preview: UIImage)
    case video(id: UUID, url: URL, preview: VideoPreview?)

    var id: UUID {
        switch self {
        case let .photo(id, _, _), let .video(id, _, _):
            id
        }
    }

    var previewImage: UIImage? {
        switch self {
        case let .photo(_, _, preview):
            preview
        case let .video(_, _, preview):
            preview?.image
        }
    }

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }

    var ownedURLs: [URL] {
        switch self {
        case let .photo(_, url, _):
            [url]
        case let .video(_, url, preview):
            [url] + [preview?.url].compactMap { $0 }
        }
    }

    var ratedPOIMedia: RatedPOI.Media {
        switch self {
        case let .photo(_, url, _):
            .init(kind: .photo(url))
        case let .video(_, url, preview):
            .init(kind: .video(url: url, poster: preview?.url))
        }
    }

    var reelAttachment: RealPost.Attachment {
        switch self {
        case let .photo(id, url, _):
            .init(id: id, kind: .photo(url))
        case let .video(id, url, preview):
            .init(id: id, kind: .video(url: url, poster: preview?.url))
        }
    }
}

/// One visual renderer keeps photo and video tiles identical throughout the
/// compact one-page Reel composer.
private struct ReelAssetVisual: View {
    let asset: ComposerMediaAsset

    var body: some View {
        Group {
            if let image = asset.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color.black, Color.black.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    if asset.isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct VideoPreview {
    let image: UIImage
    let url: URL
}

/// UIImage is immutable for this pipeline. The wrapper makes that explicit
/// while JPEG encoding runs off the UI actor.
private struct SendableComposerImage: @unchecked Sendable {
    let image: UIImage

    init(_ image: UIImage) {
        self.image = image
    }
}

nonisolated private struct ImportedComposerPhoto: Transferable, Sendable {
    let url: URL
    let preview: LocalMapDecodedImage

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try await ComposerPhotoProcessor.shared.prepare(at: received.file)
        }
    }
}

private actor ComposerPhotoProcessor {
    static let shared = ComposerPhotoProcessor()

    func prepare(at source: URL) throws -> ImportedComposerPhoto {
        let photo = try PublishPhotoNormalizer.prepare(at: source)
        let url = try MapTalkMediaStorage.persist(photo.jpegData, fileExtension: "jpg")
        return ImportedComposerPhoto(url: url, preview: photo.preview)
    }
}

nonisolated private struct ImportedMovie: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let bytes = try received.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0, bytes <= PublishVideoNormalizer.maximumSourceBytes else {
                throw PublishVideoNormalizer.ImportError.tooLarge
            }
            let url = try MapTalkMediaStorage.directory()
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            let capacity = try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            if let capacity, capacity < Int64(bytes + PublishVideoNormalizer.maximumFileBytes * 3) {
                throw PublishVideoNormalizer.ImportError.insufficientSpace
            }
            do {
                try FileManager.default.copyItem(at: received.file, to: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return Self(url: url)
        }
    }
}

private enum MapTalkMediaStorage {
    /// `Transferable` imports video files off the main actor. Keeping this
    /// tiny file operation nonisolated prevents an import from hopping back to
    /// UI state merely to copy bytes into app-owned storage.
    nonisolated static func directory() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapTalkMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated static func persist(_ data: Data, fileExtension: String) throws -> URL {
        let url = try directory()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }
}

private func makeVideoPreview(for movieURL: URL) async throws -> VideoPreview {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movieURL))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 960, height: 960)
    let generated = try await generator.image(at: .zero)
    let image = UIImage(cgImage: generated.image)
    guard let data = image.jpegData(compressionQuality: 0.86) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let url = try MapTalkMediaStorage.directory()
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jpg")
    try data.write(to: url, options: .atomic)
    return VideoPreview(image: image, url: url)
}

private struct ComposerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Matches the quiet chronology used by MyMap's main List while remaining
/// compact enough for multi-select. It is navigation context, not a third
/// Bubble type: every row still selects an ordinary memory.
private struct BubbleDateHeader: View {
    let title: String
    let count: Int
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(seasonTint)
                .frame(width: 6, height: 6)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)

            Spacer(minLength: 8)

            Text(count.formatted())
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.28))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) \(count == 1 ? "memory" : "memories")")
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
