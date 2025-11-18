import SwiftUI

// MARK: - Helpers

extension RealPost.Visibility {
    var displayName: String {
        switch self {
        case .publicAll:
            return "Public"
        case .friendsOnly:
            return "Friends"
        case .anonymous:
            return "Anonymous"
        }
    }
}

extension Array where Element == Int {
    var average: Double? {
        guard isEmpty == false else { return nil }
        let total = reduce(0, +)
        return Double(total) / Double(count)
    }
}
