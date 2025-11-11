import Foundation
import SwiftUI

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

    var accentColor: Color {
        switch self {
        case .viewpoint:
            return Theme.neonPrimary
        case .restaurant:
            return .orange
        case .coffee:
            return .brown
        case .nightlife:
            return Theme.neonAccent
        case .art:
            return Theme.neonWarning
        case .market:
            return .teal
        }
    }

    var markerGradientColors: [Color] {
        switch self {
        case .viewpoint:
            return [Color.cyan, Color.blue]
        case .restaurant:
            return [Color.orange, Color.red]
        case .coffee:
            return [Color.brown, Color.orange.opacity(0.8)]
        case .nightlife:
            return [Color.purple, Color.indigo]
        case .art:
            return [Color.pink, Color.purple]
        case .market:
            return [Color.yellow, Color.orange.opacity(0.9)]
        }
    }

    var defaultEmoji: String {
        switch self {
        case .viewpoint:
            return "📷"
        case .restaurant:
            return "🍽️"
        case .coffee:
            return "☕️"
        case .nightlife:
            return "🎶"
        case .art:
            return "🎨"
        case .market:
            return "🛍️"
        }
    }
}
