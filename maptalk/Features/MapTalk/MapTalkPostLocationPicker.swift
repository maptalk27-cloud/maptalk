import CoreLocation
import SwiftUI

/// A small step inside the Post composer. The owner supplies personal history;
/// choosing a row changes only this draft's coordinate, never its content.
struct MapTalkPostLocationPicker: View {
    let library: MapTalkPostLocationLibrary
    let liveLocation: CLLocation?
    @Binding var query: String
    let selection: MapTalkPostLocationSelection?
    let onSelect: (MapTalkPostLocationSelection?) -> Void
    let onBack: () -> Void

    @FocusState private var isSearchFocused: Bool
    @State private var isChoosingOnMap = false

    private var choices: [MapTalkPostLocationChoice] { library.choices(matching: query) }
    private var canOpenMap: Bool {
        liveLocation != nil || !library.coverage.areas.isEmpty || !library.choices.isEmpty
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            if isChoosingOnMap {
                MapTalkCustomPostLocationPicker(library: library, origin: liveLocation, selection: selection,
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
                isLoading: false, identifier: "maptalk.post.location-search",
                placeholder: "Search your Post locations")
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    PublishLocationSectionHeader(title: "Your Post locations")
                    ForEach(choices) { choice in
                        VStack(spacing: 0) {
                            PublishLocationDivider()
                            choiceRow(choice)
                        }
                    }
                    if choices.isEmpty {
                        emptyState(symbol: "mappin.slash",
                                   title: isSearching ? "No matching Post locations" : "No Post locations yet",
                                   detail: isSearching ? "Try another location name."
                                    : canOpenMap ? "Create a new location on the map."
                                    : "Enable location to create your first Post location.")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 0) {
                PublishLocationDivider()
                PublishLocationCreateButton(isEnabled: canOpenMap,
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

    private func choiceRow(_ choice: MapTalkPostLocationChoice) -> some View {
        let selected = isSelected(choice)
        return Button {
            isSearchFocused = false
            onSelect(choice.selection)
        } label: {
            PublishLocationChoiceLabel(title: Self.displayTitle(for: choice),
                subtitle: postCountText(choice), symbol: "mappin", isSelected: selected,
                thumbnailURL: choice.thumbnailURL)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.displayTitle(for: choice))
        .accessibilityValue([postCountText(choice), selected ? "selected" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("maptalk.post.location-option.\(choice.id)")
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
        return selection.locationID == choice.selection.locationID
            && selection.title == choice.selection.title
            && selection.coordinate.latitude == choice.selection.coordinate.latitude
            && selection.coordinate.longitude == choice.selection.coordinate.longitude
    }

    private func postCountText(_ choice: MapTalkPostLocationChoice) -> String {
        "\(choice.postCount) \(choice.postCount == 1 ? "post" : "posts")"
    }

    static func displayTitle(for choice: MapTalkPostLocationChoice) -> String {
        guard choice.selection.locationName == nil,
              choice.selection.title == "Previous post location",
              let text = choice.previousPosts.first?.message?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return choice.selection.title
        }
        // Display-only fallback. Reuse always keeps the original nil name.
        return text.replacingOccurrences(of: "\n", with: " ")
    }

}
