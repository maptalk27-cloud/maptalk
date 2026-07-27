import MapKit
import SwiftUI

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

    var cityName: String {
        UserMapCity.label(for: coordinate)
    }

    static func make(
        reels: [RealPost],
        footprints: [UserMapViewModel.Footprint],
        user: User
    ) -> [UserMapRecord] {
        let journeys = reels
            .compactMap(\.capsuleId)
            .reduce(into: [UUID]()) { ids, id in
                if ids.contains(id) == false { ids.append(id) }
            }
            .compactMap(PreviewData.journey(for:))
            .filter { $0.userId == user.id }

        let journeyRecords = journeys.map {
            UserMapRecord(id: $0.id, timestamp: $0.createdAt, kind: .journey($0))
        }
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
        return (journeyRecords + reelRecords + poiRecords)
            .sorted { $0.timestamp > $1.timestamp }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct UserMapHomeView: View {
    private enum Display: Equatable { case list, map }
    fileprivate enum RecordType: String, CaseIterable, Identifiable, Hashable {
        case poi = "POI"
        case reel = "Reel"
        case journey = "Journey"

        var id: Self { self }
        var icon: String {
            switch self {
            case .poi: "mappin"
            case .reel: "play.rectangle"
            case .journey: "map"
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

    let user: User
    let region: MKCoordinateRegion
    let records: [UserMapRecord]
    let userProvider: (UUID) -> User?

    @State private var display: Display = .list
    @State private var searchText = ""
    @State private var selectedTypes = Set(RecordType.allCases)
    @State private var selectedCity: String?
    @State private var datePreset: DatePreset = .anyTime
    @State private var customStartDate = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customEndDate = Date.now
    @State private var isFilterPresented = false
    @State private var selectedRecord: UserMapRecord?
    @State private var mapPreview: UserMapRecord?
    @State private var cameraPosition: MapCameraPosition

    init(
        user: User,
        region: MKCoordinateRegion,
        records: [UserMapRecord],
        userProvider: @escaping (UUID) -> User?
    ) {
        self.user = user
        self.region = region
        self.records = records
        self.userProvider = userProvider
        _cameraPosition = State(initialValue: .region(region))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            switch display {
            case .list:
                listContent
            case .map:
                mapContent
            }

            viewToggle
                .padding(.bottom, display == .list ? 18 : 28)
        }
        .navigationTitle("MyMap")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search places and memories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isFilterPresented = true
                } label: {
                    Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter records")
            }
        }
        .sheet(item: $selectedRecord) { record in
            UserMapRecordDetail(record: record, userProvider: userProvider)
                .presentationDetents([.fraction(0.32), .large])
                .presentationBackground(.thinMaterial)
        }
        .sheet(isPresented: $isFilterPresented) {
            UserMapFilterSheet(
                cities: availableCities,
                selectedTypes: $selectedTypes,
                selectedCity: $selectedCity,
                datePreset: $datePreset,
                customStartDate: $customStartDate,
                customEndDate: $customEndDate
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var filteredRecords: [UserMapRecord] {
        records.filter { record in
            guard selectedTypes.contains(recordType(for: record)) else { return false }
            guard selectedCity == nil || selectedCity == record.cityName else { return false }
            guard matchesDate(record.timestamp) else { return false }
            guard searchText.isEmpty == false else { return true }
            return record.title.localizedCaseInsensitiveContains(searchText)
                || record.cityName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var availableCities: [String] {
        Array(Set(records.map(\.cityName))).sorted()
    }

    private var hasActiveFilters: Bool {
        selectedTypes.count != RecordType.allCases.count || selectedCity != nil || datePreset != .anyTime
    }

    private func recordType(for record: UserMapRecord) -> RecordType {
        switch record.kind {
        case .poi: .poi
        case .reel: .reel
        case .journey: .journey
        }
    }

    private func matchesDate(_ date: Date) -> Bool {
        let calendar = Calendar.current
        switch datePreset {
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
            let start = calendar.startOfDay(for: min(customStartDate, customEndDate))
            let endDay = calendar.startOfDay(for: max(customStartDate, customEndDate))
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

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24, pinnedViews: .sectionHeaders) {
                if filteredRecords.isEmpty {
                    ContentUnavailableView(
                        "No records found",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search or filter.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }

                ForEach(groupedRecords, id: \.0) { section in
                    Section {
                        VStack(spacing: 0) {
                            ForEach(Array(section.1.enumerated()), id: \.element.id) { index, record in
                                Button {
                                    selectedRecord = record
                                } label: {
                                    UserMapRecordCard(record: record)
                                }
                                .buttonStyle(.plain)

                                if index < section.1.count - 1 {
                                    Divider()
                                        .padding(.leading, 70)
                                }
                            }
                        }
                    } header: {
                        Text(section.0)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .background(Color(.systemBackground))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 94)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var mapContent: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
            ForEach(filteredRecords) { record in
                Annotation(record.title, coordinate: record.coordinate) {
                    Button {
                        mapPreview = record
                    } label: {
                        mapMarker(for: record)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .bottom) {
            if let mapPreview {
                Button {
                    selectedRecord = mapPreview
                } label: {
                    UserMapRecordPreview(record: mapPreview)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 92)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func mapMarker(for record: UserMapRecord) -> some View {
        switch record.kind {
        case let .poi(rated):
            UserMapMarker(category: rated.poi.category)
        case let .reel(reel):
            RealMapThumbnail(real: reel, user: userProvider(reel.userId), size: 38)
        case .journey:
            Image(systemName: "map.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Theme.neonAccent, in: Circle())
                .overlay { Circle().stroke(Color.white.opacity(0.7), lineWidth: 2) }
                .shadow(color: Theme.neonAccent.opacity(0.45), radius: 8, y: 3)
        }
    }

    private var viewToggle: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                display = display == .list ? .map : .list
            }
        } label: {
            Label(display == .list ? "Map" : "List", systemImage: display == .list ? "map" : "list.bullet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 17)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.88), in: Capsule())
                .shadow(color: Color.black.opacity(0.22), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(display == .list ? "Show map" : "Show list")
    }

    private func sectionTitle(for record: UserMapRecord) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(record.timestamp) { return "Today" }
        if calendar.isDate(record.timestamp, equalTo: .now, toGranularity: .weekOfYear) { return "This Week" }
        return record.timestamp.formatted(.dateTime.month(.wide).year())
    }
}

private enum UserMapCity {
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

private struct UserMapFilterSheet: View {
    let cities: [String]
    @Binding var selectedTypes: Set<UserMapHomeView.RecordType>
    @Binding var selectedCity: String?
    @Binding var datePreset: UserMapHomeView.DatePreset
    @Binding var customStartDate: Date
    @Binding var customEndDate: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(UserMapHomeView.RecordType.allCases) { type in
                        Button {
                            toggle(type)
                        } label: {
                            HStack {
                                Label(type.rawValue, systemImage: type.icon)
                                Spacer()
                                Image(systemName: selectedTypes.contains(type) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedTypes.contains(type) ? Theme.neonPrimary : .secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Record type")
                } footer: {
                    Text("Choose one or more kinds of memories.")
                }

                Section("Time") {
                    Picker("When", selection: $datePreset) {
                        ForEach(UserMapHomeView.DatePreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }

                    if datePreset == .custom {
                        DatePicker("From", selection: $customStartDate, displayedComponents: .date)
                        DatePicker("To", selection: $customEndDate, displayedComponents: .date)
                    }
                }

                Section {
                    Picker("Location", selection: $selectedCity) {
                        Text("All cities").tag(String?.none)
                        ForEach(cities, id: \.self) { city in
                            Text(city).tag(Optional(city))
                        }
                    }
                } header: {
                    Text("City")
                } footer: {
                    Text("Cities are inferred from the saved location. A future location search can replace this with geocoded places.")
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        selectedTypes = Set(UserMapHomeView.RecordType.allCases)
                        selectedCity = nil
                        datePreset = .anyTime
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Show results") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func toggle(_ type: UserMapHomeView.RecordType) {
        if selectedTypes.contains(type) {
            guard selectedTypes.count > 1 else { return }
            selectedTypes.remove(type)
        } else {
            selectedTypes.insert(type)
        }
    }
}

private struct UserMapRecordCard: View {
    let record: UserMapRecord

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(record.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 6)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var thumbnail: some View {
        Group {
            switch record.kind {
            case let .poi(rated):
                Image(systemName: rated.poi.category.symbolName)
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(LinearGradient(colors: rated.poi.category.markerGradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            case let .reel(reel):
                reelThumbnail(reel)
            case .journey:
                Image(systemName: "map.fill")
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Theme.neonAccent)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func reelThumbnail(_ reel: RealPost) -> some View {
        if let url = reel.attachments.compactMap(mediaPreviewURL).first {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFill()
                case .empty: ProgressView()
                default: reelFallback
                }
            }
            .frame(width: 58, height: 58)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(Color.black.opacity(0.52), in: Circle())
            }
        } else {
            reelFallback
        }
    }

    private var reelFallback: some View {
        ZStack {
            Theme.neonPrimary.opacity(0.7)
            Image(systemName: "play.fill").foregroundStyle(.white)
        }
        .frame(width: 58, height: 58)
    }

    private func mediaPreviewURL(_ attachment: RealPost.Attachment) -> URL? {
        switch attachment.kind {
        case let .photo(url): return url
        case let .video(_, poster): return poster
        case .emoji: return nil
        }
    }

    private var subtitle: String {
        switch record.kind {
        case let .poi(rated): return rated.poi.category.displayName
        case .reel: return "Reel"
        case let .journey(journey): return "\(journey.reels.count + journey.pois.count) memories"
        }
    }
}

private struct UserMapRecordPreview: View {
    let record: UserMapRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.neonPrimary)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(.headline).lineLimit(1)
                Text("Tap to open").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct UserMapRecordDetail: View {
    let record: UserMapRecord
    let userProvider: (UUID) -> User?

    var body: some View {
        switch record.kind {
        case let .poi(rated):
            ExperienceDetailView(ratedPOI: rated, isExpanded: true, userProvider: userProvider)
        case let .reel(reel):
            ExperienceDetailView(
                sequencePager: .init(items: [.init(id: reel.id, mode: .real(reel, userProvider(reel.userId)))]),
                selection: .constant(reel.id),
                isExpanded: true,
                userProvider: userProvider
            )
        case let .journey(journey):
            ExperienceDetailView(
                sequencePager: .init(items: [.init(id: journey.id, mode: .journey(journey))]),
                selection: .constant(journey.id),
                isExpanded: true,
                userProvider: userProvider
            )
        }
    }
}
