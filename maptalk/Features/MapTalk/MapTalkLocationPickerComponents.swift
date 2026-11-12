import SwiftUI

/// Shared presentation only. POI and Post retain their own location rules.
struct PublishLocationPickerHeader: View {
    let title: String
    let backLabel: String
    let backIdentifier: String
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(backLabel)
                .accessibilityIdentifier(backIdentifier)
                Spacer()
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .frame(height: 46)
    }
}

struct PublishLocationSearchField: View {
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding
    let isLoading: Bool
    let identifier: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(Color.black.opacity(0.42))
            TextField("Search nearby places", text: $text)
                .font(.system(size: 15))
                .foregroundStyle(.black)
                .focused(isFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { isFocused.wrappedValue = false }
                .accessibilityIdentifier(identifier)
            if isLoading {
                ProgressView().controlSize(.small).tint(.gray)
                    .accessibilityLabel("Loading nearby places")
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.black.opacity(0.3))
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear location search")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty ? 14 : 4)
        .frame(height: 44)
        .background(Color(red: 0.95, green: 0.95, blue: 0.965),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PublishLocationCreateButton: View {
    var title: String = "Create new"
    var isEnabled: Bool = true
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.black)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityIdentifier(identifier)
    }
}

struct PublishLocationChoiceLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    let isSelected: Bool
    var badge: String? = nil
    var thumbnailURL: URL? = nil
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.58))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
                            .fixedSize()
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.53))
                        .lineLimit(2)
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.black.opacity(0.46))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: detail == nil ? 58 : 74)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnailURL {
            MapImage(url: thumbnailURL) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    symbolImage
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
        } else {
            symbolImage
        }
    }

    private var symbolImage: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(Color.black.opacity(0.58))
            .frame(width: 36, height: 36)
            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

/// Personal history and public activity are labelled separately in both pickers.
enum PublishLocationText {
    static func distance(_ meters: Double) -> String {
        let meters = max(0, meters)
        return meters < 1_000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters / 1_000)
    }

    static func ownActivity(posts: Int = 0, checkIns: Int, latest: Date?) -> String? {
        var parts: [String] = []
        if posts > 0 { parts.append("\(posts) \(posts == 1 ? "post" : "posts")") }
        if checkIns > 0 { parts.append("\(checkIns) \(checkIns == 1 ? "check-in" : "check-ins")") }
        guard !parts.isEmpty else { return nil }
        if let latest {
            let format: Date.FormatStyle = Calendar.current.isDate(latest, equalTo: .now, toGranularity: .year)
                ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year()
            parts.append("Last \(latest.formatted(format))")
        }
        return "You · " + parts.joined(separator: " · ")
    }
}

extension MapTalkNearbyPlaceOption {
    var historyBadge: String? {
        if !ownCheckIns.isEmpty { return "Been here" }
        if !friendUsers.isEmpty { return "Friends" }
        return publicVisitorCount > 0 ? "Check-ins" : nil
    }

    var historyDetail: String? {
        if let own = PublishLocationText.ownActivity(checkIns: ownCheckIns.count,
                                                    latest: ownCheckIns.first?.activityDate) { return own }
        var parts: [String] = []
        if !friendUsers.isEmpty {
            parts.append("\(friendUsers.count) \(friendUsers.count == 1 ? "friend" : "friends")")
        }
        if publicVisitorCount > 0 {
            parts.append("\(publicVisitorCount) \(publicVisitorCount == 1 ? "person" : "people") checked in")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var locationSubtitle: String {
        let category = place.poi.directoryKind == .airport ? "Airport" : place.poi.category.displayName
        return "\(PublishLocationText.distance(distanceMeters)) · \(category)"
    }
}

extension MapTalkPostLocationChoice {
    var historyBadge: String? {
        if postCount > 0 { return "Posted here" }
        return placeOption?.historyBadge ?? (isPOI ? "POI" : nil)
    }

    var historyDetail: String? {
        PublishLocationText.ownActivity(posts: postCount, checkIns: ownCheckInCount,
                                       latest: lastOwnActivityAt) ?? placeOption?.historyDetail
    }

    var locationSubtitle: String {
        if let placeOption { return placeOption.locationSubtitle }
        return [PublishLocationText.distance(distanceMeters), category?.displayName]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct PublishLocationSectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.48))
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.black.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .frame(height: 42)
    }
}

struct PublishLocationDivider: View {
    var body: some View {
        Rectangle().fill(Color.black.opacity(0.085)).frame(height: 0.5)
    }
}
