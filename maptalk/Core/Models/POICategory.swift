import Foundation

enum POICategory: String, CaseIterable, Codable {
    case viewpoint
    case restaurant
    case coffee
    case nightlife
    case art
    case market

    var displayName: String {
        switch self {
        case .viewpoint:
            return "Viewpoint"
        case .restaurant:
            return "Restaurant"
        case .coffee:
            return "Coffee"
        case .nightlife:
            return "Nightlife"
        case .art:
            return "Art Spot"
        case .market:
            return "Market"
        }
    }

    var symbolName: String {
        switch self {
        case .viewpoint:
            return "camera.fill"
        case .restaurant:
            return "fork.knife"
        case .coffee:
            return "cup.and.saucer.fill"
        case .nightlife:
            return "music.mic"
        case .art:
            return "paintpalette.fill"
        case .market:
            return "cart.fill"
        }
    }
}
