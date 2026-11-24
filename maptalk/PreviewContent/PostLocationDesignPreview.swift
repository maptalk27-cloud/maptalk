#if DEBUG && targetEnvironment(simulator)
import CoreLocation
import MapKit
import SwiftUI

/// Exercises the actual picker with isolated authored history. Selection only
/// acknowledges the tap; Back enters the regular mock app, never an account.
struct PostLocationPickerPreview: View {
    let onClose: () -> Void
    @State private var notice: String?
    @State private var noticeID = UUID()

    var body: some View {
        MapTalkCustomPostLocationPicker(library: LocationDesignFixture.pickerLibrary,
            origin: CLLocation(latitude: LocationDesignFixture.origin.latitude,
                               longitude: LocationDesignFixture.origin.longitude),
            selection: nil, onSelect: { selection in
                notice = "Selected · \(selection.title)"
                noticeID = UUID()
            }, onBack: onClose)
            .overlay(alignment: .top) {
                if let notice {
                    Text(notice)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 58)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("location-picker-preview.selection")
                }
            }
            .task(id: noticeID) {
                guard notice != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                notice = nil
            }
    }
}

/// Isolated visual comparison. No account, archive, draft or publication writes.
struct PostLocationDesignPreview: View {
    let onClose: () -> Void

    @State private var style: PostLocationPreviewStyle = .mint
    @State private var scene: LocationDesignFixture.Scene = .seattle
    @State private var camera = LocationDesignFixture.seattle.region
    @State private var cameraID = UUID()
    @State private var center = LocationDesignFixture.seattle.region.center
    @State private var selected: PostLocationPreviewPin?
    @State private var name = ""
    @State private var confirmed = false
    @FocusState private var isNaming: Bool

    private var fixture: LocationDesignFixture { LocationDesignFixture.fixture(scene) }
    private var allowed: Bool {
        fixture.coverage.contains(center, currentLocation: CLLocation(
            latitude: LocationDesignFixture.origin.latitude,
            longitude: LocationDesignFixture.origin.longitude))
    }
    private var canUse: Bool {
        selected != nil || (allowed && PostLocationPolicy.normalizedName(name) != nil)
    }
    private let tint = Color(red: 0.23, green: 0.52, blue: 0.44)

    var body: some View {
        VStack(spacing: 0) {
            controls
            HStack {
                Image(systemName: "chevron.left").frame(width: 44, height: 40)
                    .accessibilityHidden(true)
                Spacer()
                Text("Create new").font(.system(size: 18, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 40)
            }
            .padding(.horizontal, 12)

            PostLocationDesignMap(style: style, areas: fixture.areas,
                pins: fixture.pins, origin: LocationDesignFixture.origin,
                camera: camera, cameraID: cameraID,
                onMove: { coordinate in
                    if abs(coordinate.latitude - center.latitude) > 0.000001
                        || abs(coordinate.longitude - center.longitude) > 0.000001 {
                        center = coordinate
                        if selected != nil { selected = nil; name = "" }
                        confirmed = false
                    }
                }, onSelect: { pin in
                    isNaming = false
                    selected = pin
                    name = pin.name
                    confirmed = false
                })
                .overlay {
                    if selected == nil {
                        Image(systemName: "mappin")
                            .font(.system(size: 35, weight: .semibold))
                            .foregroundStyle(allowed ? Color.black : Color(red: 0.65, green: 0.35, blue: 0.25))
                            .shadow(color: .white.opacity(0.95), radius: 2)
                            .offset(y: -17)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .top) {
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 7, height: 7)
                        Text(style == .focus ? "Choose within the clear area" : "Your areas · 5 km around visits")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12).allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    Menu {
                        Button("Near you") { move(to: LocationDesignFixture.origin) }
                        if !fixture.pins.isEmpty {
                            Section("Your Post places") {
                                ForEach(fixture.pins) { pin in
                                    Button("\(pin.name) · \(pin.count) Posts") {
                                        move(to: pin.coordinate)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Your places", systemImage: "map")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 13).frame(height: 42)
                            .background(.regularMaterial, in: Capsule())
                    }.padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button { move(to: LocationDesignFixture.origin) } label: {
                        Image(systemName: "location.fill").font(.system(size: 16))
                            .frame(width: 42, height: 42)
                            .background(.regularMaterial, in: Circle())
                    }.buttonStyle(.plain).padding(12)
                        .accessibilityLabel("Return to current location")
                }
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 16)

            namingControls
        }
        .background(.white)
        .foregroundStyle(.black)
        .tint(.black)
        .preferredColorScheme(.light)
        .accessibilityIdentifier("maptalk.post-location-design-preview")
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("地点选址 · 设计预览").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Mock").font(.caption).foregroundStyle(.secondary)
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 36, height: 30)
                }.buttonStyle(.plain).accessibilityLabel("关闭设计预览")
            }
            Picker("地图设计", selection: $style) {
                ForEach(PostLocationPreviewStyle.allCases) { design in
                    Text(design.title).tag(design)
                }
            }.pickerStyle(.segmented)
                .accessibilityIdentifier("location-preview.design")
            HStack {
                Menu {
                    ForEach(LocationDesignFixture.Scene.allCases) { item in
                        Button(item.title) { changeScene(item) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(scene.title)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }.font(.system(size: 12, weight: .medium)).frame(minHeight: 30)
                }.accessibilityIdentifier("location-preview.scenario")
                Spacer()
                Button("复位") { changeScene(scene) }
                    .font(.system(size: 12)).frame(minHeight: 30)
                    .accessibilityIdentifier("location-preview.reset")
            }
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
        .background(Color(white: 0.96))
    }

    private var namingControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: selected != nil ? "square.stack" : allowed ? "checkmark.circle" : "arrow.up.right")
                    .foregroundStyle(allowed || selected != nil ? tint : Color.secondary)
                Text(selected.map { "Existing place · \($0.count) Posts" }
                    ?? (allowed ? "You can create a place here" : "Move into one of your areas"))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if selected != nil {
                    Button("Choose new") { selected = nil; name = ""; confirmed = false }
                        .underline()
                }
            }.font(.system(size: 12)).frame(height: 24)
                .accessibilityIdentifier("location-preview.status")

            TextField("Name this location", text: $name)
                .font(.system(size: 16, weight: selected == nil ? .regular : .medium))
                .padding(.horizontal, 14).frame(height: 48)
                .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))
                .focused($isNaming).disabled(selected != nil)
                .submitLabel(.done).onSubmit { isNaming = false }

            Button {
                isNaming = false
                confirmed = true
            } label: {
                Text(confirmed ? "Selected · preview only" : selected == nil ? "Use this place" : "Continue here")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 50)
                    .background(canUse ? Color.black : Color.black.opacity(0.2),
                                in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain).disabled(!canUse)
            Text("Tap a Post pin to use that place")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 10)
    }

    private func move(to coordinate: CLLocationCoordinate2D) {
        isNaming = false
        selected = nil
        name = ""
        confirmed = false
        center = coordinate
        camera = .init(center: coordinate, latitudinalMeters: 16_000, longitudinalMeters: 16_000)
        cameraID = UUID()
    }

    private func changeScene(_ scene: LocationDesignFixture.Scene) {
        self.scene = scene
        isNaming = false
        selected = nil
        name = ""
        confirmed = false
        camera = fixture.region
        center = fixture.region.center
        cameraID = UUID()
    }
}

private struct LocationDesignFixture {
    enum Scene: String, CaseIterable, Identifiable {
        case seattle, hawaii, dense, empty
        var id: Self { self }
        var title: String {
            switch self {
            case .seattle: "Seattle · 合并区域"
            case .hawaii: "Hawaii · 以前去过"
            case .dense: "Seattle · 地点较多"
            case .empty: "没有历史地点"
            }
        }
    }

    let region: MKCoordinateRegion
    let visits: [PostLocationVisitArea]
    let pins: [PostLocationPreviewPin]
    let coverage: PostLocationCoverage
    var areas: [CLLocationCoordinate2D] { visits.map(\.coordinate) }

    static let origin = CLLocationCoordinate2D(latitude: 47.59, longitude: -122.322)
    private static let photos = [
        "https://images.unsplash.com/photo-1507525428034-b723cf961d3e?auto=format&fit=crop&w=160&q=75",
        "https://images.unsplash.com/photo-1441974231531-c6227db76b6e?auto=format&fit=crop&w=160&q=75",
        "https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=160&q=75"
    ]
    private static func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
    private static func pin(_ name: String, _ count: Int, _ latitude: Double,
                            _ longitude: Double, _ image: Int) -> PostLocationPreviewPin {
        .init(id: UUID(), name: name, count: count, coordinate: coordinate(latitude, longitude), imageName: photos[image % photos.count])
    }
    private init(center: CLLocationCoordinate2D, visits: [(String, CLLocationCoordinate2D)], pins: [PostLocationPreviewPin]) {
        region = .init(center: center, latitudinalMeters: 18_000, longitudinalMeters: 18_000)
        self.visits = visits.map { PostLocationVisitArea(id: UUID(), name: $0.0, coordinate: $0.1) }
        self.pins = pins
        coverage = .init(areas: self.visits)
    }
    static let seattle = LocationDesignFixture(center: coordinate(47.628, -122.335),
        visits: [("Fremont", coordinate(47.65, -122.35))], pins: [
            pin("Sunday by the water", 8, 47.599, -122.342, 0),
            pin("Slow mornings", 3, 47.66, -122.354, 1),
            pin("Our sunset spot", 2, 47.638, -122.402, 2),
            pin("Lake days", 4, 47.666, -122.25, 0)
        ])
    static let hawaii = LocationDesignFixture(center: coordinate(21.306, -157.858),
        visits: [("Waikiki", coordinate(21.279, -157.829)), ("Kakaako", coordinate(21.298, -157.86))], pins: [
            pin("Our Hawaii days", 12, 21.278, -157.829, 0),
            pin("Slow island mornings", 4, 21.316, -157.858, 1),
            pin("Last sunset", 2, 21.29, -157.89, 2),
            pin("Another island memory", 3, 21.36, -157.88, 0)
        ])
    static let dense = LocationDesignFixture(center: seattle.region.center,
        visits: [("Fremont", coordinate(47.65, -122.35))], pins: seattle.pins + [
            pin("After work", 2, 47.62, -122.305, 1),
            pin("Rainy afternoons", 6, 47.665, -122.39, 2),
            pin("The little corner", 1, 47.581, -122.38, 0),
            pin("Nothing planned", 5, 47.64, -122.29, 1)
        ])
    static let empty = LocationDesignFixture(center: origin, visits: [], pins: [])

    /// Feed fixtures through the real ownership/grouping/coverage model rather
    /// than constructing picker choices or bypassing its eligibility rules.
    static let pickerLibrary: MapTalkPostLocationLibrary = {
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let fixtures = [seattle, hawaii]
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let posts = fixtures.flatMap(\.pins).enumerated().flatMap { pinIndex, pin in
            (0..<pin.count).map { visitIndex in
                RealPost(id: UUID(), userId: owner, center: pin.coordinate, radiusMeters: 220,
                    message: "Preview memory", attachments: [.init(kind: .photo(URL(string: pin.imageName)!))],
                    likes: [], comments: [], visibility: visitIndex.isMultiple(of: 2) ? .privateOnly : .publicAll,
                    createdAt: date.addingTimeInterval(-Double(pinIndex * 100 + visitIndex) * 86_400),
                    expiresAt: .distantFuture, locationName: pin.name, locationID: pin.id)
            }
        }
        let places = fixtures.flatMap(\.visits).map { area in
            RatedPOI(poi: .init(id: area.id, name: area.name, coordinate: area.coordinate, category: .viewpoint),
                highlight: nil, secondary: nil, media: [],
                checkIns: [.init(userId: owner, createdAt: date)], comments: [],
                endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0),
                tags: [], isFavoritedByCurrentUser: false, favoritesCount: 0)
        }
        return MapTalkPostLocationLibrary(ownPosts: posts, visitedPlaces: places, currentUserID: owner)
    }()

    static func fixture(_ scene: Scene) -> Self {
        switch scene {
        case .seattle: seattle
        case .hawaii: hawaii
        case .dense: dense
        case .empty: empty
        }
    }
}
#endif
