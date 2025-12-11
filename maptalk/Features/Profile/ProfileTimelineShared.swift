import Combine
import MapKit
import SwiftUI
import UIKit

// MARK: - Timeline shared models

enum TimelineEventKind {
    case reel(RealPost, User?)
    case poi(RatedPOI)

    var priority: Int {
        switch self {
        case .reel: return 1
        case .poi: return 0
        }
    }
}

struct TimelineEvent: Identifiable {
    let id: UUID
    let date: Date
    let coordinate: CLLocationCoordinate2D
    let kind: TimelineEventKind

    var labelHint: String? {
        switch kind {
        case let .reel(real, _):
            return PreviewData.locationLabel(for: real.id)
        case let .poi(rated):
            return PreviewData.locationLabel(for: rated.poi.id)
        }
    }
}

struct TimelineSegment: Identifiable {
    // Deterministic ID so SwiftUI keeps image loading state stable while the map spins.
    var id: String { "\(label)-\(Int(start.timeIntervalSince1970))" }
    let label: String
    var start: Date
    var end: Date
    var events: [TimelineEvent]
}

enum TimelineAnimationStyle: String, CaseIterable {
    case none = "No Animation"
    case smooth = "Smooth"
    case bouncy = "Bouncy"
    case snappy = "Snappy"
    case materialBlur = "Material Blur"
    case dimmed = "Dim & Desaturate"

    var title: String { rawValue }

    var animation: Animation? {
        switch self {
        case .none:
            return nil
        case .smooth:
            return .smooth(duration: 0.45)
        case .bouncy:
            return .bouncy(duration: 0.6, extraBounce: 0.24)
        case .snappy:
            return .snappy(duration: 0.35, extraBounce: 0.14)
        case .materialBlur:
            return .smooth(duration: 0.5)
        case .dimmed:
            return .smooth(duration: 0.45)
        }
    }

    var visualEffect: TimelineVisualEffect? {
        switch self {
        case .materialBlur:
            return .materialBlur
        case .dimmed:
            return .dimmed
        case .none, .smooth, .bouncy, .snappy:
            return nil
        }
    }
}

enum TimelineVisualEffect {
    case materialBlur
    case dimmed
}

// MARK: - Timeline UI

struct PreviewTimelineAxis: View {
    let segments: [TimelineSegment]
    var selectedId: String?
    var selectedProgress: Double?
    var onSelect: ((TimelineSegment) -> Void)?
    var onScrollStateChange: ((Bool) -> Void)?

    @State private var isDragging: Bool = false

    init(
        segments: [TimelineSegment],
        selectedId: String? = nil,
        selectedProgress: Double? = nil,
        onSelect: ((TimelineSegment) -> Void)? = nil,
        onScrollStateChange: ((Bool) -> Void)? = nil
    ) {
        self.segments = segments
        self.selectedId = selectedId
        self.selectedProgress = selectedProgress
        self.onSelect = onSelect
        self.onScrollStateChange = onScrollStateChange
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(segments.enumerated()), id: \.1.id) { index, segment in
                        let isLast = index == segments.count - 1
                        let isSelected = segment.id == selectedId
                        HStack(alignment: .center, spacing: 12) {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(isSelected ? Color.white : Color.pink)
                                    .frame(width: 12, height: 12)
                                    .overlay {
                                        Circle().stroke(Color.white.opacity(0.9), lineWidth: 2)
                                    }
                                Rectangle()
                                    .fill(Color.white.opacity(isLast ? 0 : 0.2))
                                    .frame(width: 2, height: isLast ? 0 : 32)
                            }
                            .frame(width: 18)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(segment.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(isSelected ? Color.white : Color.white)
                                Text(dateRangeText(for: segment))
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.7))
                                avatarStack(for: segment)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            timelineRowBackground(isSelected: isSelected, progress: selectedProgress)
                        )
                        .padding(.horizontal, -6)
                        .contentShape(Rectangle())
                        .id(segment.id)
                        .onTapGesture {
                            onSelect?(segment)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .onChange(of: selectedId, initial: false) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                guard let id = selectedId else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            .simultaneousGesture(
                DragGesture()
                    .onChanged { _ in
                        guard isDragging == false else { return }
                        isDragging = true
                        onScrollStateChange?(true)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onScrollStateChange?(false)
                    }
            )
        }
    }

    private func avatarStack(for segment: TimelineSegment) -> some View {
        // Favor reels so their thumbnails surface even when POI visits dominate.
        let events = segment.events.sorted { lhs, rhs in
            if lhs.kind.priority != rhs.kind.priority {
                return lhs.kind.priority > rhs.kind.priority
            }
            return lhs.date > rhs.date
        }
        let rows = chunked(events, size: 13)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: -10) {
                    ForEach(row) { event in
                        avatar(for: event)
                            .frame(width: 34, height: 34)
                    }
                }
            }
        }
    }

    private func timelineRowBackground(isSelected: Bool, progress: Double?) -> some View {
        let base = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let clamped = min(max(progress ?? 0, 0), 1)
        return ZStack(alignment: .leading) {
            base
                .fill(isSelected ? Color.white.opacity(0.08) : Color.white.opacity(0))

            if isSelected {
                GeometryReader { geometry in
                    let width = geometry.size.width * clamped
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.32),
                                    Theme.neonPrimary.opacity(0.18)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(width, 0))
                }
                .allowsHitTesting(false)

                base
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.16),
                                Color.white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            }

            base
                .stroke(Color.white.opacity(isSelected ? 0.12 : 0.06), lineWidth: 1)
        }
    }
}

private func chunked<T>(_ items: [T], size: Int) -> [[T]] {
    guard size > 0 else { return [items] }
    var result: [[T]] = []
    var index = 0
    while index < items.count {
        let end = min(index + size, items.count)
        result.append(Array(items[index..<end]))
        index += size
    }
    return result
}

private func avatar(for event: TimelineEvent) -> some View {
    switch event.kind {
    case let .reel(real, user):
        return AnyView(
            RealMapThumbnail(real: real, user: user, size: 34)
        )
    case let .poi(poi):
        return AnyView(
            ProfileMapMarker(category: poi.poi.category)
                .frame(width: 30, height: 33)
        )
    }
}

private struct TimelineRowProgressBar: View {
    let progress: Double

    var body: some View {
        let accent = Theme.neonPrimary
        GeometryReader { geometry in
            let clamped = min(max(progress, 0), 1)
            let width = geometry.size.width * clamped
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.75))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.95), accent.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: 0.7)
            )
        }
        .frame(height: 8)
    }
}

private func dateRangeText(for segment: TimelineSegment) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    if Calendar.current.isDate(segment.start, inSameDayAs: segment.end) {
        return formatter.string(from: segment.start)
    }
    return "\(formatter.string(from: segment.start)) - \(formatter.string(from: segment.end))"
}

// MARK: - Utilities

@MainActor
final class TimelineCityResolver: ObservableObject {
    @Published private var labels: [String: String] = [:]

    func label(for coordinate: CLLocationCoordinate2D, preferred: String? = nil) -> String {
        let key = Self.cacheKey(for: coordinate)
        if let cached = labels[key] {
            return cached
        }
        if let preferred, preferred.isEmpty == false {
            return preferred
        }
        return Self.fallbackLabel(for: coordinate)
    }

    private static func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.3f,%.3f", coordinate.latitude, coordinate.longitude)
    }

    private static func fallbackLabel(for coordinate: CLLocationCoordinate2D) -> String {
        let candidates: [(String, CLLocationCoordinate2D)] = [
            ("Xi'an, Shaanxi, China", .init(latitude: 34.341, longitude: 108.939)),
            ("Hangzhou, Zhejiang, China", .init(latitude: 30.274, longitude: 120.155)),
            ("Suzhou, Jiangsu, China", .init(latitude: 31.298, longitude: 120.583)),
            ("Seattle, Washington, USA", .init(latitude: 47.6062, longitude: -122.3321))
        ]

        let current = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best: (String, CLLocationDistance)?
        for candidate in candidates {
            let dist = current.distance(from: CLLocation(latitude: candidate.1.latitude, longitude: candidate.1.longitude))
            if best == nil || dist < best!.1 {
                best = (candidate.0, dist)
            }
        }

        if let best, best.1 < 600_000 {
            return best.0
        }
        return String(format: "Lat %.3f, Lon %.3f", coordinate.latitude, coordinate.longitude)
    }
}

struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midX = rect.midX
        let midY = rect.midY
        path.move(to: CGPoint(x: midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        path.addLine(to: CGPoint(x: midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: midY))
        path.closeSubpath()
        return path
    }
}

func poiPreview(for rated: RatedPOI, size: CGFloat) -> some View {
    let shape = DiamondShape()
    let fillColor = (rated.poi.category.markerGradientColors.first ?? rated.poi.category.accentColor).opacity(0.9)

    return ZStack {
        fillColor
        ProfileMapMarker(category: rated.poi.category)
            .frame(width: size, height: size * 1.1)
    }
    .frame(width: size, height: size)
    .clipShape(shape)
    .overlay {
        shape.stroke(Color.white.opacity(0.85), lineWidth: 1)
    }
}

struct ProfileMapMarker: View {
    let category: POICategory

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(markerGradient)
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(45))
                .shadow(color: markerGlow.opacity(0.45), radius: 6, y: 2)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.4), lineWidth: 0.8)
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(45))
            Image(systemName: category.symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var markerGradient: LinearGradient {
        LinearGradient(
            colors: category.markerGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var markerGlow: Color {
        category.markerGradientColors.last ?? category.accentColor
    }
}

struct RealMapThumbnail: View {
    let real: RealPost
    let user: User?
    var size: CGFloat = 40

    private var mediaURL: URL? {
        for attachment in real.attachments {
            switch attachment.kind {
            case let .photo(url):
                return url
            case let .video(_, poster):
                if let poster { return poster }
            case .emoji:
                continue
            }
        }
        return nil
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.45))
                .overlay {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 1)
                }

            if let url = mediaURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    case .failure:
                        avatarFallback
                    @unknown default:
                        avatarFallback
                    }
                }
                .clipShape(Circle())
            } else if let avatar = user?.avatarURL {
                AsyncImage(url: avatar) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    case .failure:
                        avatarFallback
                    @unknown default:
                        avatarFallback
                    }
                }
                .clipShape(Circle())
            } else {
                avatarFallback
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .stroke(Theme.neonPrimary.opacity(0.7), lineWidth: 2)
        }
        .shadow(color: Color.black.opacity(0.45), radius: 6, y: 3)
    }

    private var avatarFallback: some View {
        Text(initials)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.4))
            .clipShape(Circle())
    }

    private var initials: String {
        guard let handle = user?.handle else { return "PO" }
        return String(handle.prefix(2)).uppercased()
    }
}

struct RoundedCorners: Shape {
    let corners: UIRectCorner
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

enum ProfileMapAnnotationZoomHelper {
    static let detailRevealMeters: CLLocationDistance = 500_0000
    static let oldReelRevealMeters: CLLocationDistance = 80_000

    static func isClose(distance: CLLocationDistance?) -> Bool {
        guard let distance else { return false }
        return distance <= detailRevealMeters
    }

    static func isClose(region: MKCoordinateRegion) -> Bool {
        maxSpanMeters(for: region) <= detailRevealMeters
    }

    static func isClose(
        distance: CLLocationDistance?,
        region: MKCoordinateRegion,
        threshold: CLLocationDistance
    ) -> Bool {
        let span = maxSpanMeters(for: region)
        let reference = distance ?? span
        return reference <= threshold
    }

    static func spanMeters(for region: MKCoordinateRegion) -> CLLocationDistance {
        maxSpanMeters(for: region)
    }

    static func nextDetailState(
        current: Bool,
        distance: CLLocationDistance?,
        region: MKCoordinateRegion
    ) -> Bool {
        let span = maxSpanMeters(for: region)
        let reference = distance ?? span
        return reference <= detailRevealMeters
    }

    private static func maxSpanMeters(for region: MKCoordinateRegion) -> CLLocationDistance {
        let center = region.center
        let halfLat = region.span.latitudeDelta / 2
        let halfLon = region.span.longitudeDelta / 2

        let west = CLLocation(latitude: center.latitude, longitude: center.longitude - halfLon)
        let east = CLLocation(latitude: center.latitude, longitude: center.longitude + halfLon)
        let horizontal = west.distance(from: east)

        let north = CLLocation(latitude: center.latitude + halfLat, longitude: center.longitude)
        let south = CLLocation(latitude: center.latitude - halfLat, longitude: center.longitude)
        let vertical = north.distance(from: south)

        return max(horizontal, vertical)
    }
}

extension View {
    @ViewBuilder
    func applyBackgroundInteractionIfAvailable() -> some View {
        if #available(iOS 17.0, *) {
            presentationBackgroundInteraction(.enabled)
        } else {
            self
        }
    }
}
