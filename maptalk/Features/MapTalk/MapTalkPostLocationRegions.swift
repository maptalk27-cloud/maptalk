import Combine
import CoreLocation
import Foundation
import MapKit

/// A navigation shortcut, not a permission area. The 50 km grouping distance
/// never replaces or expands the independent 5 km PostLocationCoverage rule.
struct PostLocationRegion: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let mapRegion: MKCoordinateRegion
    let fallbackTitle: String
}

enum MapTalkPostLocationRegions {
    static let groupingDistance: CLLocationDistance = 50_000

    private struct Point: Hashable {
        let latitude: Double
        let longitude: Double
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
        var vector: [Double] {
            let lat = latitude * .pi / 180
            let lon = longitude * .pi / 180
            return [cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat)]
        }
    }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
        let z: Int
        init(_ point: Point) {
            let size = groupingDistance / 6_330_000
            let vector = point.vector
            x = Int(floor(vector[0] / size))
            y = Int(floor(vector[1] / size))
            z = Int(floor(vector[2] / size))
        }
        init(x: Int, y: Int, z: Int) { self.x = x; self.y = y; self.z = z }
    }

    static func make(coordinates: [CLLocationCoordinate2D]) -> [PostLocationRegion] {
        let points = Set(coordinates.compactMap { coordinate -> Point? in
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
                  CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return Point(latitude: coordinate.latitude,
                         longitude: abs(coordinate.latitude) == 90 ? 0
                            : coordinate.longitude == 180 ? -180 : coordinate.longitude)
        }).sorted { $0.latitude == $1.latitude ? $0.longitude < $1.longitude : $0.latitude < $1.latitude }
        var groups: [[Point]] = []
        var buckets: [Cell: [Int]] = [:]
        for point in points {
            let cell = Cell(point)
            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
            var nearest: Int?
            var nearestDistance = groupingDistance
            for x in (cell.x - 1)...(cell.x + 1) {
                for y in (cell.y - 1)...(cell.y + 1) {
                    for z in (cell.z - 1)...(cell.z + 1) {
                        for index in buckets[Cell(x: x, y: y, z: z)] ?? [] {
                            let anchor = groups[index][0]
                            let distance = location.distance(from: CLLocation(latitude: anchor.latitude,
                                                                              longitude: anchor.longitude))
                            if distance < nearestDistance
                                || (distance == nearestDistance && index < (nearest ?? Int.max)) {
                                nearest = index
                                nearestDistance = distance
                            }
                        }
                    }
                }
            }
            if let nearest {
                groups[nearest].append(point)
            } else {
                buckets[cell, default: []].append(groups.count)
                groups.append([point])
            }
        }
        // Anchors stay fixed: a chain of visits cannot turn an entire coast
        // into one enormous navigation region. Input order cannot alter groups.
        return groups.map { points in
            let anchor = points[0]
            let id = "region:\(Int64((anchor.latitude * 1_000_000).rounded())):\(Int64((anchor.longitude * 1_000_000).rounded()))"
            return PostLocationRegion(id: id, coordinate: anchor.coordinate, mapRegion: viewport(points),
                                      fallbackTitle: fallbackTitle(anchor.coordinate))
        }
    }

    private static func viewport(_ points: [Point]) -> MKCoordinateRegion {
        let latitudes = points.map(\.latitude)
        let minLatitude = latitudes.min() ?? 0
        let maxLatitude = latitudes.max() ?? 0
        let latitude = (minLatitude + maxLatitude) / 2
        let longitudes = points.map { $0.longitude < 0 ? $0.longitude + 360 : $0.longitude }.sorted()
        var largestGap = -Double.infinity
        var arcStart = longitudes[0]
        for index in longitudes.indices {
            let next = index + 1 < longitudes.count ? longitudes[index + 1] : longitudes[0] + 360
            if next - longitudes[index] > largestGap {
                largestGap = next - longitudes[index]
                arcStart = next.truncatingRemainder(dividingBy: 360)
            }
        }
        let longitudeWidth = max(0, 360 - largestGap)
        let centerLongitude = (arcStart + longitudeWidth / 2 + 180).truncatingRemainder(dividingBy: 360) - 180
        let longitudePadding = 0.14 / max(0.01, cos(latitude * .pi / 180))
        return .init(center: .init(latitude: latitude, longitude: centerLongitude),
            span: .init(latitudeDelta: min(180, max(0.18, (maxLatitude - minLatitude + 0.14) * 1.15)),
                        longitudeDelta: abs(latitude) > 89.8 ? 360
                            : min(360, max(longitudePadding, (longitudeWidth + longitudePadding) * 1.15))))
    }

    private static func fallbackTitle(_ coordinate: CLLocationCoordinate2D) -> String {
        let latitude = String(format: "%.1f°%@", abs(coordinate.latitude), coordinate.latitude < 0 ? "S" : "N")
        let longitude = String(format: "%.1f°%@", abs(coordinate.longitude), coordinate.longitude < 0 ? "W" : "E")
        return "Region · \(latitude), \(longitude)"
    }
}

/// Resolve only visible region rows, never every POI or every map movement.
/// Shared in-memory results survive reopening the picker; failures also cache
/// the honest coordinate fallback instead of retrying on every row appearance.
@MainActor
final class PostLocationRegionNameResolver: ObservableObject {
    typealias Lookup = @MainActor (CLLocationCoordinate2D) async -> String?
    static let shared = PostLocationRegionNameResolver()

    @Published private(set) var names: [String: String] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private let lookup: Lookup
    private let spacing: Duration
    private let defaults: UserDefaults?
    private let storageKey = "maptalk.postLocationRegionNames.v1.\(Locale.current.identifier)"
    private var savedNames: [String: String] = [:]
    private var savedOrder: [String] = []

    init(spacing: Duration = .seconds(1), defaults: UserDefaults? = .standard, lookup: Lookup? = nil) {
        self.spacing = spacing
        self.defaults = defaults
        self.lookup = lookup ?? { coordinate in
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            let locality = placemark.locality?.trimmingCharacters(in: .whitespacesAndNewlines)
            let area = placemark.administrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines)
            let components = [locality, area].compactMap { $0 }.filter { !$0.isEmpty }
            var seen = Set<String>()
            let title = components.filter { seen.insert($0).inserted }.joined(separator: ", ")
            return title.isEmpty ? nil : title
        }
        if let stored = defaults?.dictionary(forKey: storageKey) as? [String: String] {
            savedOrder = Array(stored.keys.sorted().suffix(256))
            savedNames = Dictionary(uniqueKeysWithValues: savedOrder.compactMap { key in stored[key].map { (key, $0) } })
            names = savedNames
        }
    }

    func title(for region: PostLocationRegion) -> String { names[region.id] ?? region.fallbackTitle }

    @discardableResult
    func resolve(_ region: PostLocationRegion) -> Task<Void, Never> {
        if names[region.id] != nil { return Task {} }
        if let request = pending[region.id] { return request }
        let previous = tail
        let request = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if previous != nil { try? await Task.sleep(for: spacing) }
            let name = await lookup(region.coordinate)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty {
                names[region.id] = name
                savedNames[region.id] = name
                savedOrder.removeAll { $0 == region.id }
                savedOrder.append(region.id)
                while savedOrder.count > 256 { savedNames[savedOrder.removeFirst()] = nil }
                defaults?.set(savedNames, forKey: storageKey)
            } else {
                names[region.id] = region.fallbackTitle
            }
            pending[region.id] = nil
        }
        pending[region.id] = request
        tail = request
        return request
    }
}
