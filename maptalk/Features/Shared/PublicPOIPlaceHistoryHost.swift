import SwiftUI

/// Opt-in only for the public map's standalone historical place entry.
/// Personal/limited projections and Bubble snapshots must not use this host:
/// their supplied membership is authoritative and must never be widened.
struct PublicPOIPlaceHistoryHost<Content: View>: View {
    let place: RatedPOI
    let isExpanded: Bool
    var isActive = true
    @ViewBuilder let content: (RatedPOI) -> Content
    @Environment(\.appEnv) private var environment

    var body: some View {
        if let backend = environment.backend {
            ConnectedPublicPOIPlaceHistory(backend: backend, placeID: place.id,
                isExpanded: isExpanded, isActive: isActive, content: content)
                .id(place.id)
        } else {
            content(place)
        }
    }
}

private struct ConnectedPublicPOIPlaceHistory<Content: View>: View {
    @ObservedObject var backend: BackendStore
    let placeID: UUID
    let isExpanded: Bool
    let isActive: Bool
    @ViewBuilder let content: (RatedPOI) -> Content
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.friendStoryPlaybackEnabled) private var playbackEnabled
    @State private var history: BackendStore.PlaceHistoryPage?
    @State private var status: Status = .idle
    @State private var pageLoadFailed = false
    @State private var retry = 0
    @State private var isVisible = false
    @State private var loadToken = UUID()

    private enum Status { case idle, loading, loaded, unavailable }
    private struct Request: Equatable {
        let placeID: UUID
        let revision: Int
        let retry: Int
    }

    private var request: Request? {
        guard isActive, isVisible, playbackEnabled, scenePhase == .active else { return nil }
        return .init(placeID: placeID, revision: backend.publicContentRevision, retry: retry)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let place = history?.place, status != .unavailable {
                content(place)
                    // The history loader owns this bounded page's media.
                    // Do not start a second whole-projection download below it.
                    .environment(\.experienceLiveMediaHydrationEnabled, false)
                if isExpanded {
                    if status == .loading {
                        ProgressView().controlSize(.small)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .accessibilityLabel("Loading earlier visits")
                    } else if history?.nextCursor != nil {
                        Button(pageLoadFailed ? "Retry earlier visits" : "Load earlier visits", action: loadMore)
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("poi.public-history.load-earlier")
                    }
                }
            } else if status == .unavailable {
                VStack(spacing: 14) {
                    Image(systemName: "mappin.slash").font(.title2)
                    Text("This place isn't available right now.").font(.subheadline)
                    Button("Try again", action: loadMore).buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading place visits")
            }
        }
        .foregroundStyle(.white)
        .background(.black)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: request) {
            guard let request, status == .idle else { return }
            await load(request)
        }
        .onReceive(backend.publicContentChanges) { _ in
            // Pages from different access revisions may never be combined,
            // even if a removed visit is not on the first visible screen.
            loadToken = UUID()
            history = nil
            status = .idle
            pageLoadFailed = false
            retry &+= 1
        }
    }

    private func loadMore() {
        guard status != .loading else { return }
        status = .idle
        retry &+= 1
    }

    private func load(_ request: Request) async {
        let token = UUID()
        loadToken = token
        let previous = history
        var hasVerifiedMetadata = previous?.revision == request.revision
        status = .loading
        pageLoadFailed = false
        do {
            // One request prepares at most 12 public visits. Older pages
            // require the explicit expanded-card action, never an auto-loop.
            let loaded = try await backend.loadPlaceHistory(placeID: placeID, after: previous,
                includeVideos: false) { updated in
                guard loadToken == token, !Task.isCancelled,
                      updated.revision == backend.publicContentRevision else { return }
                hasVerifiedMetadata = true
                history = updated
            }
            guard loadToken == token else { return }
            guard !Task.isCancelled else {
                history = previous
                status = .idle
                return
            }
            history = loaded.place == nil ? nil : loaded
            status = loaded.place == nil ? .unavailable : .loaded
        } catch {
            guard loadToken == token else { return }
            if Task.isCancelled, request.revision == backend.publicContentRevision {
                // Resume the interrupted page later, not the following page
                // after a partially prepared metadata callback.
                history = previous
                status = .idle
            } else if BackendStore.canRetainVerifiedPlaceHistory(after: error,
                hasVerifiedMetadata: hasVerifiedMetadata, requestRevision: request.revision,
                currentRevision: backend.publicContentRevision, isActive: backend.isActive) {
                status = .loaded
                pageLoadFailed = history?.nextCursor == previous?.nextCursor && previous != nil
            } else {
                history = nil
                status = .unavailable
            }
        }
    }
}
