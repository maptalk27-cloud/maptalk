#if DEBUG
import CoreLocation
import Foundation

/// Deliberately different visit histories, not a counter attached to one photo.
/// Every scenario is local to the design playground; visits retain real place boundaries.
enum POICardPreviewCase: String, CaseIterable, Identifiable {
    case single, repeated, multiplePeople, interleaved, myHistory, mixedHistory, latestWithoutMedia, empty
    case multiplePlaces
    // Append new cases so the original scenarios keep their deterministic IDs.
    case oneFriend, twoFriends, threeFriends, fiveFriends
    case tenFriends, twentyFriends, fiftyFriends

    enum MediaKind: String, CaseIterable, Identifiable {
        case mixed, photo, video, none
        var id: Self { self }
        var title: String {
            switch self {
            case .mixed: "图＋视频"
            case .photo: "照片"
            case .video: "视频"
            case .none: "无媒体"
            }
        }
    }

    var id: Self { self }
    var title: String {
        switch self {
        case .single: "一人一次"
        case .repeated: "一人连续多次"
        case .multiplePlaces: "一人多个地点"
        case .multiplePeople: "多人各一次"
        case .interleaved: "多人交错重复"
        case .myHistory: "我的历史打卡"
        case .mixedHistory: "大家的历史打卡"
        case .latestWithoutMedia: "最新一次无媒体"
        case .empty: "尚无打卡"
        case .oneFriend: "1 位朋友来过"
        case .twoFriends: "2 位朋友来过"
        case .threeFriends: "3 位朋友来过"
        case .fiveFriends: "5 位朋友来过"
        case .tenFriends: "10 位朋友来过"
        case .twentyFriends: "20 位朋友来过"
        case .fiftyFriends: "50 位朋友来过"
        }
    }

    var subtitle: String {
        switch self {
        case .single: "1 人 · 1 次 · 单张媒体"
        case .repeated: "同一人连续 3 次 · 其中一次有 2 张媒体"
        case .multiplePlaces: "同一人 · 咖啡店 → 公园 → 餐厅 · 餐厅有 2 张媒体"
        case .multiplePeople: "4 人各 1 次 · 包括我"
        case .interleaved: "A → A → B → B → A → C → 我 · A 再次出现"
        case .myHistory: "只有我的 5 次历史到访 · 四天前到一年以前"
        case .mixedHistory: "4 人 9 次 · 连续、隔天、跨月、跨年"
        case .latestWithoutMedia: "最新一次只有感受 · 旧照片不能冒充这一次"
        case .empty: "0 人 · 0 次 · 空状态"
        case .oneFriend: "1 位朋友 · 1 次 · 同一地点 · 不包括我"
        case .twoFriends: "2 位朋友 · 2 次 · 同一地点 · 不包括我"
        case .threeFriends: "3 位朋友 · 4 次 · 一位重复到访 · 不包括我"
        case .fiveFriends: "5 位朋友 · 6 次 · 一位重复到访 · 不包括我"
        case .tenFriends: "10 位朋友 · 11 次 · 一位重复到访 · 不包括我"
        case .twentyFriends: "20 位朋友 · 21 次 · 一位重复到访 · 不包括我"
        case .fiftyFriends: "50 位朋友 · 51 次 · 一位重复到访 · 不包括我"
        }
    }

    var customizedFriendCount: Int? {
        switch self {
        case .oneFriend: 1
        case .twoFriends: 2
        case .threeFriends: 3
        case .fiveFriends: 5
        case .tenFriends: 10
        case .twentyFriends: 20
        case .fiftyFriends: 50
        default: nil
        }
    }

    /// A cached, playground-only roster; it never changes the app's friend list.
    @MainActor
    static let customizedFriends: [User] = {
        var seen: Set<UUID> = [PreviewData.currentUser.id]
        var people = PreviewData.sampleFriends.prefix(5).filter { seen.insert($0.id).inserted }
        let avatars = people.compactMap(\.avatarURL)
        for index in people.count..<50 {
            let id = UUID(uuidString: String(format: "B9516900-0000-4000-8000-%012d", index + 1))!
            people.append(User(id: id, handle: String(format: "demo.friend.%02d", index + 1),
                               avatarURL: avatars.isEmpty ? nil : avatars[index % avatars.count]))
        }
        return people
    }()

    private struct VisitSeed {
        let person: Int // A, B, C, me; independent from sequence position.
        let secondsAgo: TimeInterval
        var mediaCount = 1
    }

    private var visits: [VisitSeed] {
        let day: TimeInterval = 86_400
        switch self {
        case .single:
            return [.init(person: 0, secondsAgo: 600)]
        case .repeated, .multiplePlaces:
            return [.init(person: 0, secondsAgo: 600, mediaCount: 2),
                    .init(person: 0, secondsAgo: 1_200),
                    .init(person: 0, secondsAgo: 2_100)]
        case .multiplePeople:
            return [.init(person: 0, secondsAgo: 300),
                    .init(person: 1, secondsAgo: 1_800),
                    .init(person: 2, secondsAgo: 4_200),
                    .init(person: 3, secondsAgo: 7_200)]
        case .interleaved:
            return [.init(person: 0, secondsAgo: 600, mediaCount: 2),
                    .init(person: 0, secondsAgo: 1_200),
                    .init(person: 1, secondsAgo: 1_800),
                    .init(person: 1, secondsAgo: 2_400),
                    .init(person: 0, secondsAgo: 4_200),
                    .init(person: 2, secondsAgo: 7_200),
                    .init(person: 3, secondsAgo: 10_800)]
        case .myHistory:
            return [.init(person: 3, secondsAgo: 4 * day),
                    .init(person: 3, secondsAgo: 14 * day, mediaCount: 2),
                    .init(person: 3, secondsAgo: 28 * day),
                    .init(person: 3, secondsAgo: 120 * day),
                    .init(person: 3, secondsAgo: 400 * day)]
        case .mixedHistory:
            return [.init(person: 0, secondsAgo: 600),
                    .init(person: 0, secondsAgo: 1_200, mediaCount: 2),
                    .init(person: 1, secondsAgo: 3_600, mediaCount: 0),
                    .init(person: 3, secondsAgo: 10_800, mediaCount: 0),
                    .init(person: 2, secondsAgo: 7 * day),
                    .init(person: 1, secondsAgo: 30 * day),
                    .init(person: 0, secondsAgo: 90 * day),
                    .init(person: 3, secondsAgo: 180 * day),
                    .init(person: 3, secondsAgo: 400 * day)]
        case .latestWithoutMedia:
            return [.init(person: 0, secondsAgo: 600, mediaCount: 0),
                    .init(person: 0, secondsAgo: 4 * day)]
        case .empty:
            return []
        case .oneFriend, .twoFriends, .threeFriends, .fiveFriends,
             .tenFriends, .twentyFriends, .fiftyFriends:
            return [] // These cases use the distinct-friend fixture builder below.
        }
    }

    @MainActor
    func makeFixtures(media: MediaKind, hasFeedback: Bool, now: Date) -> [RatedPOI] {
        if let friendCount = customizedFriendCount {
            return Self.makeFriendsFixture(friendCount: friendCount, media: media,
                                           hasFeedback: hasFeedback, now: now)
        }
        let base = makeFixture(media: media, hasFeedback: hasFeedback, now: now)
        guard self == .multiplePlaces else { return [base] }
        let stops: [(String, Double, Double, POICategory)] = [
            ("Bellevue Roastery", 47.6140, -122.2010, .coffee),
            ("Downtown Park", 47.6104, -122.2038, .viewpoint),
            ("Old Bellevue Bistro", 47.6100, -122.2057, .restaurant)
        ]
        let visits = base.checkIns.sorted { $0.activityDate < $1.activityDate }
        return stops.enumerated().map { index, stop in
            let poi = POI(id: sampleID(5_000 + index), name: stop.0,
                coordinate: .init(latitude: stop.1, longitude: stop.2), category: stop.3)
            var visit = visits[index]
            visit.comment = hasFeedback ? ["先喝杯咖啡。", "沿着公园走了一圈。", "最后和朋友一起吃晚饭。"][index] : nil
            var place = RatedPOI(poi: poi, highlight: nil, secondary: nil,
                media: visit.media, checkIns: [visit], comments: [],
                endorsements: .init(hype: 0, solid: 0, meh: 0, questionable: 0),
                tags: [], isFavoritedByCurrentUser: false, favoritesCount: base.favoritesCount)
            place.refreshEndorsementSummary()
            return place
        }
    }

    @MainActor
    func makeFixture(media: MediaKind, hasFeedback: Bool, now: Date) -> RatedPOI {
        if let friendCount = customizedFriendCount {
            return Self.makeFriendsFixture(friendCount: friendCount, media: media,
                                           hasFeedback: hasFeedback, now: now)[0]
        }
        var place = PreviewData.sampleRatedPOIs[1]
        let people = Array(PreviewData.sampleFriends.prefix(3)) + [PreviewData.currentUser]
        let photos = PreviewData.sampleRatedPOIs.flatMap(\.media).compactMap { item -> URL? in
            if case let .photo(url) = item.kind { return url }
            return nil
        }
        let videoURL = Bundle.main.url(forResource: "istockphoto-1467181036-640_adpp_is", withExtension: "mp4")
            ?? Bundle.main.url(forResource: "istockphoto-1467181036-640_adpp_is", withExtension: "mp4", subdirectory: "Mock")
        let ratings: [RatedPOI.Endorsement?] = [.hype, .solid, nil, .meh, .questionable]
        let thoughts = ["窗边的光很好，咖啡也刚刚好。", "又坐回了熟悉的位置。",
                        "今天和朋友一起过来。", "有点吵，下次换个时间。", "这次感觉一般。"]
        place.checkIns = visits.enumerated().map { index, visit in
            let attachments: [RatedPOI.Media] = media == .none ? [] : (0..<visit.mediaCount).compactMap { slot in
                let mediaIndex = index * 2 + slot
                guard !photos.isEmpty else { return nil }
                let photo = photos[mediaIndex % photos.count]
                let wantsVideo = media == .video || (media == .mixed && mediaIndex % 3 == 1)
                let kind: RatedPOI.Media.Kind = wantsVideo && videoURL != nil
                    ? .video(url: videoURL!, poster: photo) : .photo(photo)
                return .init(id: sampleID(1_000 + mediaIndex), kind: kind)
            }
            return .init(id: sampleID(index + 1), userId: people[visit.person].id,
                         createdAt: now.addingTimeInterval(-visit.secondsAgo),
                         endorsement: hasFeedback ? ratings[index % ratings.count] : nil,
                         media: attachments,
                         comment: hasFeedback && index % 4 != 3 ? thoughts[index % thoughts.count] : nil)
        }
        // The declared rows and the actual stored history use the same order.
        place.checkIns.sort { $0.activityDate > $1.activityDate }
        place.media = place.checkIns.flatMap(\.media)
        place.comments = hasFeedback && !place.checkIns.isEmpty ? [
            .init(id: sampleID(9_000), userId: people[1].id,
                  content: .text("周末早上人会少一点。"), createdAt: now.addingTimeInterval(-3_600))
        ] : []
        place.highlight = nil
        place.secondary = nil
        place.tags = []
        place.favoritesCount = self == .empty ? 0 : 7
        place.isFavoritedByCurrentUser = false
        place.refreshEndorsementSummary()
        return place
    }

    /// Uses the preview-only friend roster at one unchanged place, never the current user.
    /// Three-or-more-friend previews include an extra visit to exercise person deduplication.
    @MainActor
    static func makeFriendsFixture(friendCount: Int, media: MediaKind,
                                   hasFeedback: Bool, now: Date) -> [RatedPOI] {
        let people = Array(customizedFriends.prefix(max(0, friendCount)))
        // Reuse the existing media/feedback settings without changing its scenarios.
        var place = Self.interleaved.makeFixture(media: media, hasFeedback: hasFeedback, now: now)
        let templates = place.checkIns
        let personIndices = Array(people.indices) + (people.count >= 3 ? [0] : [])
        place.checkIns = personIndices.enumerated().map { index, personIndex in
            let occurrence = index < people.count ? 0 : 1
            let template = templates[index % templates.count]
            let attachments = template.media.enumerated().map { slot, item in
                RatedPOI.Media(id: friendsSampleID(100_000 + personIndex * 100 + occurrence * 10 + slot),
                               kind: item.kind)
            }
            return .init(id: friendsSampleID(1 + personIndex * 10 + occurrence),
                         userId: people[personIndex].id,
                         createdAt: now.addingTimeInterval(-TimeInterval(600 + index * 900)),
                         endorsement: template.endorsement, media: attachments,
                         comment: template.comment)
        }
        place.media = place.checkIns.flatMap(\.media)
        place.comments = []
        place.favoritesCount = people.isEmpty ? 0 : 7
        place.refreshEndorsementSummary()
        return [place]
    }

    private static func friendsSampleID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "B9516800-0000-4000-8000-%012d", value))!
    }

    private func sampleID(_ value: Int) -> UUID {
        let scenario = Self.allCases.firstIndex(of: self) ?? 0
        return UUID(uuidString: String(format: "B9516700-0000-4000-8000-%012d", scenario * 10_000 + value))!
    }
}
#endif
