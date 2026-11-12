import CoreLocation
import SwiftUI

/// A small step inside the Post composer. The owner supplies nearby results;
/// choosing a row changes only this draft's coordinate, never its content.
struct MapTalkPostLocationPicker: View {
    let choices: [MapTalkPostLocationChoice]
    let isLoading: Bool
    let issue: POISearchIssue?
    let hasLiveLocation: Bool
    let liveLocation: CLLocation?
    @Binding var query: String
    let selection: MapTalkPostLocationSelection?
    let onSelect: (MapTalkPostLocationSelection?) -> Void
    let onBack: () -> Void
    let onRetry: () -> Void

    @FocusState private var isSearchFocused: Bool
    @State private var isChoosingOnMap = false

    private var previousLocations: [MapTalkPostLocationChoice] {
        choices.filter { $0.postCount > 0 }
    }

    private var nearbyLocations: [MapTalkPostLocationChoice] {
        choices.filter { $0.postCount == 0 }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            if isChoosingOnMap, let liveLocation {
                MapTalkCustomPostLocationPicker(origin: liveLocation, selection: selection,
                    onSelect: onSelect, onBack: { isChoosingOnMap = false })
                    .transition(.move(edge: .trailing))
            } else {
                locationList
                    .transition(.move(edge: .leading))
            }
        }
        .clipped()
        .animation(.easeOut(duration: 0.2), value: isChoosingOnMap)
    }

    private var locationList: some View {
        VStack(spacing: 0) {
            PublishLocationPickerHeader(title: "Choose a place", backLabel: "Back to post",
                backIdentifier: "maptalk.post.location-back") {
                    isSearchFocused = false
                    onBack()
                }
            PublishLocationSearchField(text: $query, isFocused: $isSearchFocused,
                isLoading: isLoading, identifier: "maptalk.post.location-search")
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if issue != nil, !isLoading, hasLiveLocation { refreshIssue }
                    if hasLiveLocation {
                        if !previousLocations.isEmpty {
                            choiceSection("Posted here", choices: previousLocations)
                        }
                        if !nearbyLocations.isEmpty || choices.isEmpty {
                            choiceSection(isSearching ? "Search results" : "Nearby places",
                                          choices: nearbyLocations, showsRange: previousLocations.isEmpty)
                        }
                    } else {
                        PublishLocationSectionHeader(title: "Nearby places", detail: "Within 5 km")
                        PublishLocationDivider()
                    }

                    if !hasLiveLocation {
                        emptyState(symbol: "location.slash", title: "Waiting for your location",
                                   detail: "Nearby places will appear when your location is available.")
                    } else {
                        if choices.isEmpty {
                            if isLoading {
                                VStack(spacing: 12) {
                                    ProgressView().controlSize(.small).tint(.black)
                                    Text(isSearching ? "Searching nearby…" : "Finding nearby places…")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 150)
                            } else if issue == nil {
                                emptyState(symbol: "mappin.slash",
                                           title: isSearching ? "No matching places nearby" : "No nearby places yet",
                                           detail: isSearching ? "Try another place name."
                                            : "Create a new location on the map.")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 0) {
                PublishLocationDivider()
                PublishLocationCreateButton(isEnabled: liveLocation != nil,
                    identifier: "maptalk.post.location-map") {
                        isSearchFocused = false
                        isChoosingOnMap = true
                    }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .background(Color.white)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.ignoresSafeArea())
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maptalk.post.location-picker")
    }

    private func choiceSection(_ title: String, choices: [MapTalkPostLocationChoice],
                               showsRange: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PublishLocationSectionHeader(title: title, detail: showsRange ? "Within 5 km" : nil)
            PublishLocationDivider()

            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 { PublishLocationDivider() }
                choiceRow(choice)
            }
        }
    }

    private func choiceRow(_ choice: MapTalkPostLocationChoice) -> some View {
        let selected = isSelected(choice)
        return Button {
            isSearchFocused = false
            onSelect(choice.selection)
        } label: {
            PublishLocationChoiceLabel(title: choice.selection.title, subtitle: summary(choice),
                symbol: choice.category?.symbolName ?? "text.alignleft", isSelected: selected,
                badge: choice.isPOI ? "POI" : nil, thumbnailURL: choice.thumbnailURL,
                detail: previousPostSnippet(choice))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.selection.title)
        .accessibilityValue("\(summary(choice))\(choice.isPOI ? ", POI" : "")\(selected ? ", selected" : "")")
        .accessibilityIdentifier("maptalk.post.location-option.\(choice.id)")
    }

    private var refreshIssue: some View {
        HStack(spacing: 12) {
            Text("Places couldn't refresh.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Try again", action: onRetry)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(minHeight: 44)
                .accessibilityIdentifier("maptalk.post.location-retry")
        }
        .frame(minHeight: 56)
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 19))
                .foregroundStyle(Color.black.opacity(0.36))
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.62))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.black.opacity(0.43))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .padding(.horizontal, 20)
    }

    private func isSelected(_ choice: MapTalkPostLocationChoice) -> Bool {
        guard let selection else { return false }
        return selection.title == choice.selection.title
            && selection.coordinate.latitude == choice.selection.coordinate.latitude
            && selection.coordinate.longitude == choice.selection.coordinate.longitude
    }

    private func previousPostSnippet(_ choice: MapTalkPostLocationChoice) -> String? {
        guard choice.selection.title == "Previous post location",
              let text = choice.previousPosts.first?.message?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    private func summary(_ choice: MapTalkPostLocationChoice) -> String {
        let meters = max(0, choice.distanceMeters)
        let distance = meters < 1_000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1_000)
        if choice.postCount > 0 {
            return "\(choice.postCount) \(choice.postCount == 1 ? "post" : "posts") · \(distance)"
        }
        return [distance, choice.category?.displayName].compactMap { $0 }.joined(separator: " · ")
    }
}
