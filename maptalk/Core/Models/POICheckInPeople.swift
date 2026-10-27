import Foundation

extension RatedPOI {
    /// A place's footprints represent people, not visits. Keep every original
    /// check-in inside the group so repeat visits and their media remain accessible.
    struct CheckInPerson {
        let userID: UUID
        let latest: CheckIn
        let checkIns: [CheckIn]
    }

    var checkInPersonCount: Int { Set(checkIns.map(\.userId)).count }

    func checkInPeople(since cutoff: Date? = nil) -> [CheckInPerson] {
        let eligible = checkIns.filter { checkIn in
            guard let cutoff else { return true }
            return checkIn.activityDate > cutoff
        }
        return Dictionary(grouping: eligible, by: \.userId).compactMap { userID, entries in
            let ordered = entries.sorted {
                if $0.activityDate != $1.activityDate { return $0.activityDate < $1.activityDate }
                return $0.id.uuidString < $1.id.uuidString
            }
            guard let latest = ordered.last else { return nil }
            return CheckInPerson(userID: userID, latest: latest, checkIns: ordered)
        }.sorted {
            if $0.latest.activityDate != $1.latest.activityDate {
                return $0.latest.activityDate > $1.latest.activityDate
            }
            return $0.userID.uuidString < $1.userID.uuidString
        }
    }
}
