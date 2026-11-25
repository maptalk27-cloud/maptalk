import CoreLocation
import Foundation

/// The server supplies the place's geographical local day (including DST).
/// Old caches and mock visits use a deterministic longitude-based fallback;
/// that approximation is not an authoritative local timezone.
enum POIVisitDay {
    static func key(for visit: RatedPOI.CheckIn, coordinate: CLLocationCoordinate2D) -> String {
        if let canonical = visit.visitDay, !canonical.isEmpty { return canonical }
        return key(for: visit.activityDate, coordinate: coordinate)
    }

    /// Legacy/mock fallback only. Match the server fallback's rounding,
    /// including negative half-hours: floor(longitude / 15 + 0.5), [-12, 12].
    static func key(for timestamp: Date, coordinate: CLLocationCoordinate2D) -> String {
        let longitude = coordinate.longitude.isFinite ? coordinate.longitude : 0
        let offsetHours = min(12, max(-12, floor(longitude / 15 + 0.5)))
        let shifted = timestamp.addingTimeInterval(offsetHours * 3_600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
