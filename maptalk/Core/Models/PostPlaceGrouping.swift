import CoreLocation
import Foundation

/// A presentation-only collection. Every member retains its original Post identity.
struct PostPlaceGroup: Identifiable {
    let id: String
    let placeKey: String
    fileprivate(set) var posts: [RealPost]

    var count: Int { posts.count }

    var latestPost: RealPost {
        posts.dropFirst().reduce(posts[0]) { latest, post in
            post.activityDate > latest.activityDate ? post : latest
        }
    }

    fileprivate init(id: String, placeKey: String, post: RealPost) {
        self.id = id
        self.placeKey = placeKey
        self.posts = [post]
    }
}

enum PostPlaceGrouping {
    enum Mode {
        /// Home Feed: another author or place ends the current run.
        case consecutive
        /// Profile: collect the author's visits to a place across time.
        case aggregate
    }

    /// Never infer that nearby coordinates or similar place names are one place.
    static func placeKey(for post: RealPost) -> String? {
        guard CLLocationCoordinate2DIsValid(post.center),
              post.center.latitude.isFinite, post.center.longitude.isFinite else { return nil }

        if let locationID = post.locationID {
            return "location:\(locationID.uuidString.lowercased())"
        }

        let name = (post.locationName ?? "")
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        // Exact bits avoid rounding adjacent venues together. Normalize ±0, which
        // represent the same coordinate, without changing any stored coordinates.
        // Older Posts have no name, so an empty name is still an exact-match key.
        let latitude = post.center.latitude == 0 ? 0.0 : post.center.latitude
        let longitude = post.center.longitude == 0 ? 0.0 : post.center.longitude
        return "legacy:\(latitude.bitPattern):\(longitude.bitPattern):\(name)"
    }

    /// Callers own visibility filtering and ordering. Neither is changed here.
    static func groups(_ posts: [RealPost], mode: Mode) -> [PostPlaceGroup] {
        var result: [PostPlaceGroup] = []
        var seenPostIDs = Set<UUID>()
        var aggregateIndices: [String: Int] = [:]
        var previousGroupKey: String?

        for post in posts where seenPostIDs.insert(post.id).inserted {
            let key = placeKey(for: post) ?? "post:\(post.id.uuidString.lowercased())"
            let groupKey = "\(post.userId.uuidString.lowercased())|\(key)"

            switch mode {
            case .consecutive:
                if previousGroupKey == groupKey, !result.isEmpty {
                    result[result.count - 1].posts.append(post)
                } else {
                    result.append(PostPlaceGroup(
                        id: "\(groupKey)|\(post.id.uuidString.lowercased())",
                        placeKey: key,
                        post: post
                    ))
                }
                previousGroupKey = groupKey
            case .aggregate:
                if let index = aggregateIndices[groupKey] {
                    result[index].posts.append(post)
                } else {
                    aggregateIndices[groupKey] = result.count
                    result.append(PostPlaceGroup(id: groupKey, placeKey: key, post: post))
                }
            }
        }

        return result
    }
}
