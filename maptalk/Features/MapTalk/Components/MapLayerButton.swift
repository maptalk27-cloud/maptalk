import MapKit
import SwiftUI

enum MapTalkMapAppearance: String, CaseIterable {
    case system, day, night

    static let storageKey = "maptalk.map-appearance"

    var title: String {
        switch self {
        case .system: "Auto"
        case .day: "Day"
        case .night: "Night"
        }
    }

    func resolved(using system: ColorScheme) -> ColorScheme {
        switch self {
        case .system: system
        case .day: .light
        case .night: .dark
        }
    }
}

enum MapTalkMapLayer: String, CaseIterable, Identifiable {
    case standard
    case satellite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .satellite: "Satellite"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard: .standard
        // Keep place names and roads on the imagery; this is still an explore map.
        case .satellite: .hybrid(elevation: .flat)
        }
    }
}

struct MapLayerButton: View {
    @Binding var selection: MapTalkMapLayer
    @AppStorage(MapTalkMapAppearance.storageKey) private var appearance: MapTalkMapAppearance = .system
    @State private var isChoosingLayer = false

    var body: some View {
        Button {
            isChoosingLayer = true
        } label: {
            Image(systemName: selection == .satellite ? "globe.americas.fill" : "map")
                .font(.system(size: 19, weight: .medium))
                .frame(width: 48, height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map layers")
        .accessibilityValue(selection.title)
        .accessibilityIdentifier("maptalk.map-layers")
        .popover(isPresented: $isChoosingLayer, arrowEdge: .trailing) {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    ForEach(MapTalkMapLayer.allCases) { layer in
                        layerOption(layer)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Map appearance")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("Map appearance", selection: $appearance) {
                        ForEach(MapTalkMapAppearance.allCases, id: \.self) { tone in
                            Text(tone.title).tag(tone)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("maptalk.map-appearance")
                }
                Divider()
                HStack {
                    Text("Post cards")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    PostCardPaletteSwitch()
                }
            }
            .frame(width: 228)
            .padding(16)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func layerOption(_ layer: MapTalkMapLayer) -> some View {
        let isSelected = selection == layer
        return Button {
            isChoosingLayer = false
            selection = layer
        } label: {
            VStack(spacing: 8) {
                MapLayerThumbnail(layer: layer)
                    .frame(width: 108, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isSelected ? Theme.neonAccent : Color.primary.opacity(0.12),
                                          lineWidth: isSelected ? 2 : 0.5)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 20, height: 20)
                                .background(Theme.neonAccent, in: Circle())
                                .padding(6)
                        }
                    }
                Text(layer.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layer.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("maptalk.layer.\(layer.rawValue)")
    }
}

/// Small illustrative previews, not extra live maps or network requests.
private struct MapLayerThumbnail: View {
    let layer: MapTalkMapLayer

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 108, y: size.height / 76)
            let satellite = layer == .satellite
            context.fill(Path(CGRect(x: 0, y: 0, width: 108, height: 76)),
                         with: .color(satellite ? Color(red: 0.30, green: 0.34, blue: 0.25)
                                              : Color(red: 0.94, green: 0.93, blue: 0.87)))

            // The same waterfront and street layout make the two styles easy to compare.
            var water = Path()
            water.move(to: CGPoint(x: 83, y: 0))
            water.addCurve(to: CGPoint(x: 69, y: 76),
                           control1: CGPoint(x: 105, y: 29), control2: CGPoint(x: 48, y: 43))
            water.addLine(to: CGPoint(x: 108, y: 76))
            water.addLine(to: CGPoint(x: 108, y: 0))
            water.closeSubpath()
            context.fill(water, with: .color(satellite ? Color(red: 0.08, green: 0.24, blue: 0.28)
                                                     : Color(red: 0.50, green: 0.80, blue: 0.91)))

            for row in 0..<5 {
                for column in 0..<5 {
                    let block = CGRect(x: 3 + column * 13, y: 3 + row * 16, width: 8, height: 10)
                    let shade = Double((row * 3 + column * 7) % 5) * 0.035
                    context.fill(Path(block), with: .color(satellite
                        ? Color(red: 0.40 + shade, green: 0.40 + shade, blue: 0.35 + shade)
                        : Color(red: 0.85, green: 0.85, blue: 0.81)))
                }
            }
            context.fill(Path(roundedRect: CGRect(x: 14, y: 18, width: 23, height: 26), cornerRadius: 3),
                         with: .color(satellite ? Color(red: 0.19, green: 0.32, blue: 0.16)
                                              : Color(red: 0.64, green: 0.80, blue: 0.56)))

            var streets = Path()
            for x in [13, 39, 65] {
                streets.move(to: CGPoint(x: x, y: 0))
                streets.addLine(to: CGPoint(x: x, y: 76))
            }
            for y in [16, 48, 64] {
                streets.move(to: CGPoint(x: 0, y: y))
                streets.addLine(to: CGPoint(x: 76, y: y))
            }
            context.stroke(streets, with: .color(satellite ? .white.opacity(0.35) : .white),
                           lineWidth: satellite ? 1 : 2.5)

            var avenue = Path()
            avenue.move(to: CGPoint(x: -4, y: 73))
            avenue.addCurve(to: CGPoint(x: 78, y: -4),
                            control1: CGPoint(x: 36, y: 67), control2: CGPoint(x: 48, y: 4))
            context.stroke(avenue, with: .color(satellite ? .black.opacity(0.25) : .gray.opacity(0.22)), lineWidth: 6)
            context.stroke(avenue, with: .color(satellite ? Color(white: 0.63) : .white), lineWidth: 3)
        }
        .accessibilityHidden(true)
    }
}

/// Map utilities share one quiet surface; publishing stays visually separate.
struct MapNavigationControls: View {
    @Binding var selection: MapTalkMapLayer
    let onLocate: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            MapLayerButton(selection: $selection)
            Button(action: onLocate) {
                Image(systemName: "location.fill")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 48, height: 54)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Current location")
            .accessibilityIdentifier("maptalk.locate")
        }
        .foregroundStyle(.primary.opacity(0.88))
        .overlay {
            Rectangle()
                .fill(.primary.opacity(0.12))
                .frame(width: 24, height: 0.5)
                .allowsHitTesting(false)
        }
        .glassEffect(.regular, in: Capsule())
        // Appearance is local to these utilities, never the map or its cards.
        .environment(\.colorScheme, selection == .satellite ? .dark : colorScheme)
    }
}
