import Foundation
import SwiftUI

enum POICategory: String, CaseIterable, Codable {
    case viewpoint
    case restaurant
    case coffee
    case nightlife
    case art
    case market
    case hotel
    case airport
    case other

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
        case .hotel:
            return "Hotel"
        case .airport:
            return "Airport"
        case .other:
            return "Other"
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
        case .hotel:
            return "bed.double.fill"
        case .airport:
            return "airplane"
        case .other:
            return "star.leadinghalf.filled"
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
        case .hotel:
            return .indigo
        case .airport:
            return .blue
        case .other:
            return .gray
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
        case .hotel:
            return [Color.indigo, Color.purple]
        case .airport:
            return [Color.blue, Color.indigo]
        case .other:
            return [Color.gray, Color.black.opacity(0.8)]
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
        case .hotel:
            return "🛏️"
        case .airport:
            return "✈️"
        case .other:
            return "⭐️"
        }
    }
}
