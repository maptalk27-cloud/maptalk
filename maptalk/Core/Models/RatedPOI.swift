import Foundation

struct RatedPOI: Identifiable, Hashable {
    let poi: POI
    var ratings: [Rating]

    var id: UUID { poi.id }

    var ratingCount: Int {
        ratings.count
    }

    var commentCount: Int {
        ratings.filter { ($0.text ?? "").isEmpty == false }.count
    }

    static func == (lhs: RatedPOI, rhs: RatedPOI) -> Bool {
        lhs.id == rhs.id && lhs.ratings == rhs.ratings
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(ratings)
    }
}

