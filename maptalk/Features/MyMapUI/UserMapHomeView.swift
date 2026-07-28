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
    let userProvider: (UUID) -> User?

    @State private var display: Display = .list
    @State private var searchText = ""
    @State private var filters = FilterState()
    @State private var filterDraft = FilterState()
    @State private var filterPresentation: FilterPresentation?
    @State private var selectedRecord: UserMapRecord?
    @State private var mapPreview: UserMapRecord?
    @State private var cameraPosition: MapCameraPosition
    @FocusState private var isSearchFocused: Bool

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
        .safeAreaInset(edge: .top, spacing: 0) {
            archiveControls
        }
        .navigationTitle("MyMap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(display == .list ? .visible : .hidden, for: .navigationBar)
        .sheet(item: $selectedRecord) { record in
            UserMapRecordDetail(record: record, userProvider: userProvider)
                .presentationDetents([.fraction(0.32), .large])
                .presentationBackground(.thinMaterial)
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
        .onChange(of: searchText) { _, _ in
            clearMapPreviewIfNeeded(using: filters)
        }
    }

    private var filteredRecords: [UserMapRecord] {
        filteredRecords(using: filters)
    }

    private func filteredRecords(using filter: FilterState) -> [UserMapRecord] {
        records.filter { record in
            guard filter.types.contains(recordType(for: record)) else { return false }
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

    private func recordType(for record: UserMapRecord) -> RecordType {
        switch record.kind {
        case .poi: .poi
        case .reel: .reel
        case .journey: .journey
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

    private var listContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26, pinnedViews: .sectionHeaders) {
                if filteredRecords.isEmpty {
                    ContentUnavailableView(
                        "No memories found",
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
                                        .padding(.leading, 76)
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 94)
        }
        .background(Color(.systemBackground))
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
        clearMapPreviewIfNeeded(using: newFilters)
        if display == .map {
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

    private func clearMapPreviewIfNeeded(using filter: FilterState) {
        guard let mapPreview,
              filteredRecords(using: filter).contains(where: { $0.id == mapPreview.id }) == false else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            self.mapPreview = nil
        }
    }

    private func focusMap(on records: [UserMapRecord]) {
        guard records.isEmpty == false else { return }

        let coordinates = records.map(\.coordinate)
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        guard let minLatitude = latitudes.min(),
              let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(),
              let maxLongitude = longitudes.max() else { return }

        let latitudeDelta = min(max((maxLatitude - minLatitude) * 1.35, 0.045), 150)
        let longitudeDelta = min(max((maxLongitude - minLongitude) * 1.35, 0.045), 320)
        let region = MKCoordinateRegion(
            center: .init(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            ),
            span: .init(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )

        withAnimation(.easeInOut(duration: 0.3)) {
            cameraPosition = .region(region)
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
            MemoryThumbnail(record: record, size: 42, cornerRadius: 12)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white, lineWidth: 2)
                }
                .shadow(color: Color.black.opacity(0.24), radius: 5, y: 2)
        }
    }

    private var viewToggle: some View {
        Button {
            let nextDisplay: Display = display == .list ? .map : .list
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                display = nextDisplay
            }
            if nextDisplay == .map {
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
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
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

private struct MemoryThumbnail: View {
    let record: UserMapRecord
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnailContent
            if case .journey = record.kind {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: max(size * 0.16, 8), weight: .bold))
                    .foregroundStyle(.white)
                    .padding(max(size * 0.09, 4))
                    .background(Color.black.opacity(0.55), in: Circle())
                    .padding(max(size * 0.07, 3))
            }
            if case .reel = record.kind {
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

private struct JourneyMemoryThumbnail: View {
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

private struct UserMapRecordPreview: View {
    let record: UserMapRecord

    var body: some View {
        HStack(spacing: 12) {
            MemoryThumbnail(record: record, size: 52, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var metadata: String {
        switch record.kind {
        case let .poi(rated): return "POI · \(rated.poi.category.displayName) · \(record.cityName)"
        case .reel: return "Reel · \(record.cityName)"
        case let .journey(journey): return "Journey · \(journey.reels.count + journey.pois.count) memories"
        }
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
