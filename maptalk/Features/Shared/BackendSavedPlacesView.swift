import SwiftUI
import CoreLocation

/// Saved places are bookmarks, never check-ins or permission to publish there.
struct BackendSavedPlacesView: View {
    @ObservedObject var store: BackendStore
    @State private var isLoading = false
    @State private var issue: String?

    var body: some View {
        List {
            if let issue { Text(issue).foregroundStyle(.secondary) }
            if store.savedPlaces.isEmpty, !isLoading, issue == nil {
                ContentUnavailableView("No saved places", systemImage: "bookmark",
                    description: Text("Save a place from its card to find it here."))
            }
            ForEach(store.savedPlaces) { saved in
                NavigationLink {
                    SavedPlaceDestination(saved: saved, store: store)
                } label: {
                    Label(saved.place.name, systemImage: "mappin")
                }
                .swipeActions {
                    Button("Unsave", role: .destructive) {
                        Task {
                            do { try await store.setPlaceSaved(saved.id, saved: false) }
                            catch { issue = poiInteractionError(error) }
                        }
                    }
                }
            }
            if isLoading { ProgressView() }
            if store.hasMoreSavedPlaces {
                Button("Load more") { Task { await load(more: true) } }.disabled(isLoading)
            }
        }
        .navigationTitle("Saved places")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load(more: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do { try await store.loadSavedPlaces(more: more); issue = nil }
        catch is CancellationError { }
        catch { issue = poiInteractionError(error) }
    }
}

private struct SavedPlaceDestination: View {
    let saved: BackendSavedPlace
    let store: BackendStore

    private var place: RatedPOI {
        .init(poi: .init(id: saved.place.id, name: saved.place.name,
            coordinate: .init(latitude: saved.place.coordinate.latitude, longitude: saved.place.coordinate.longitude),
            category: POICategory(rawValue: saved.place.category) ?? .other),
            highlight: nil, secondary: nil, media: [], checkIns: [], comments: [],
            endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0), tags: [],
            isFavoritedByCurrentUser: true, favoritesCount: 0)
    }

    var body: some View {
        PublicPOIPlaceHistoryHost(place: place, isExpanded: true) { loaded in
            ExperienceDetailView(mode: .poi(loaded), isExpanded: true,
                usesUpdatedPOIStyle: true, userProvider: store.user(for:))
        }
        .navigationTitle(saved.place.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
