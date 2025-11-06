import CoreLocation
import Foundation

enum PreviewData {
    static let currentUser: User = .init(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1") ?? UUID(),
        handle: "maptalk.me",
        avatarURL: URL(string: "https://images.unsplash.com/photo-1494790108377-be9c29b29330?auto=format&fit=crop&w=200&q=60")
    )

    static let sampleFriends: [User] = [
        .init(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE2") ?? UUID(),
            handle: "aurora.wave",
            avatarURL: URL(string: "https://images.unsplash.com/photo-1521572163474-6864f9cf17ab?auto=format&fit=crop&w=200&q=60")
        ),
        .init(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE3") ?? UUID(),
            handle: "nightmarket.dj",
            avatarURL: URL(string: "https://images.unsplash.com/photo-1535713875002-d1d0cf377fde?auto=format&fit=crop&w=200&q=60")
        ),
        .init(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE4") ?? UUID(),
            handle: "skyline.runner",
            avatarURL: URL(string: "https://images.unsplash.com/photo-1504593811423-6dd665756598?auto=format&fit=crop&w=200&q=60")
        ),
        .init(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE5") ?? UUID(),
            handle: "bund.wanderer",
            avatarURL: URL(string: "https://images.unsplash.com/photo-1489515217757-5fd1be406fef?auto=format&fit=crop&w=200&q=60")
        )
    ]

    static let sampleRatedPOIs: [RatedPOI] = {
        let waterfront = POI(
            id: UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444") ?? UUID(),
            name: "Kirkland Waterfront",
            coordinate: .init(latitude: 47.676, longitude: -122.209),
            category: .viewpoint
        )

        let cafe = POI(
            id: UUID(uuidString: "BBBBBBBB-5555-6666-7777-888888888888") ?? UUID(),
            name: "Seattle Cafe",
            coordinate: .init(latitude: 47.61, longitude: -122.33),
            category: .coffee
        )

        let nightMarket = POI(
            id: UUID(uuidString: "BBBBBBBB-9999-AAAA-BBBB-CCCCCCCCCCCC") ?? UUID(),
            name: "Capitol Hill Night Market",
            coordinate: .init(latitude: 47.6153, longitude: -122.3228),
            category: .nightlife
        )

        let artMuseum = POI(
            id: UUID(uuidString: "BBBBBBBB-DDDD-EEEE-FFFF-111111111111") ?? UUID(),
            name: "Bellevue Art Museum",
            coordinate: .init(latitude: 47.615, longitude: -122.203),
            category: .art
        )

        let restaurant = POI(
            id: UUID(uuidString: "BBBBBBBB-1212-3434-5656-787878787878") ?? UUID(),
            name: "Waterfront Bistro",
            coordinate: .init(latitude: 47.6075, longitude: -122.3405),
            category: .restaurant
        )

        return [
            RatedPOI(
                poi: waterfront,
                ratings: [
                    Rating(
                        id: UUID(),
                        userId: sampleFriends[0].id,
                        poiId: waterfront.id,
                        score: 5,
                        emoji: "😎",
                        text: "Sunset vibes!",
                        visibility: .publicAll,
                        createdAt: .init()
                    ),
                    Rating(
                        id: UUID(),
                        userId: currentUser.id,
                        poiId: waterfront.id,
                        score: nil,
                        emoji: "📸",
                        text: "Captured the glow hour here.",
                        visibility: .friendsOnly,
                        createdAt: .init().addingTimeInterval(-1800)
                    )
                ]
            ),
            RatedPOI(
                poi: cafe,
                ratings: [
                    Rating(
                        id: UUID(),
                        userId: sampleFriends[1].id,
                        poiId: cafe.id,
                        score: 4,
                        emoji: "☕️",
                        text: "Nitro cold brew hits different.",
                        visibility: .friendsOnly,
                        createdAt: .init().addingTimeInterval(-3600)
                    ),
                    Rating(
                        id: UUID(),
                        userId: sampleFriends[2].id,
                        poiId: cafe.id,
                        score: 5,
                        emoji: "🥐",
                        text: "Matcha croissant is a must.",
                        visibility: .publicAll,
                        createdAt: .init().addingTimeInterval(-4200)
                    )
                ]
            ),
            RatedPOI(
                poi: nightMarket,
                ratings: [
                    Rating(
                        id: UUID(),
                        userId: currentUser.id,
                        poiId: nightMarket.id,
                        score: nil,
                        emoji: "🛍️",
                        text: "Glow sticks + vinyl pop-up tonight!",
                        visibility: .anonymous,
                        createdAt: .init().addingTimeInterval(-10800)
                    )
                ]
            ),
            RatedPOI(
                poi: artMuseum,
                ratings: [
                    Rating(
                        id: UUID(),
                        userId: sampleFriends[0].id,
                        poiId: artMuseum.id,
                        score: 5,
                        emoji: "🎨",
                        text: "Immersive light installation just opened.",
                        visibility: .publicAll,
                        createdAt: .init().addingTimeInterval(-7200)
                    )
                ]
            ),
            RatedPOI(
                poi: restaurant,
                ratings: [
                    Rating(
                        id: UUID(),
                        userId: sampleFriends[2].id,
                        poiId: restaurant.id,
                        score: 4,
                        emoji: "🍣",
                        text: "Toro tasting flight worth every credit.",
                        visibility: .friendsOnly,
                        createdAt: .init().addingTimeInterval(-2400)
                    ),
                    Rating(
                        id: UUID(),
                        userId: currentUser.id,
                        poiId: restaurant.id,
                        score: 5,
                        emoji: "🍷",
                        text: "Neon omakase night = unforgettable.",
                        visibility: .publicAll,
                        createdAt: .init().addingTimeInterval(-3600)
                    )
                ]
            )
        ]
    }()

    static var samplePOIs: [POI] {
        sampleRatedPOIs.map(\.poi)
    }

    static var sampleRatings: [Rating] {
        sampleRatedPOIs.flatMap(\.ratings)
    }

    static let sampleReals: [RealPost] = [
        .init(
            id: .init(),
            userId: currentUser.id,
            center: .init(latitude: 47.61, longitude: -122.33),
            radiusMeters: 600,
            message: "Drone light show countdown on Pier 62.",
            media: .video(
                url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!,
                poster: URL(string: "https://images.unsplash.com/photo-1534447677768-be436bb09401?auto=format&fit=crop&w=900&q=60")
            ),
            metrics: .init(likeCount: 268, commentCount: 34),
            visibility: .friendsOnly,
            createdAt: .init(),
            expiresAt: .init().addingTimeInterval(24 * 3600)
        ),
        .init(
            id: .init(),
            userId: sampleFriends[0].id,
            center: .init(latitude: 47.62, longitude: -122.21),
            radiusMeters: 600,
            message: "Projection art lighting up the old station.",
            media: .photo(URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=900&q=60")!),
            metrics: .init(likeCount: 412, commentCount: 58),
            visibility: .publicAll,
            createdAt: .init().addingTimeInterval(-5400),
            expiresAt: .init().addingTimeInterval(18 * 3600)
        ),
        .init(
            id: .init(),
            userId: sampleFriends[1].id,
            center: .init(latitude: 47.6185, longitude: -122.342),
            radiusMeters: 600,
            message: "Pop-up street dance class just kicked off.",
            media: .none,
            metrics: .init(likeCount: 97, commentCount: 11),
            visibility: .anonymous,
            createdAt: .init().addingTimeInterval(-10_800),
            expiresAt: .init().addingTimeInterval(12 * 3600)
        ),
        .init(
            id: .init(),
            userId: sampleFriends[2].id,
            center: .init(latitude: 47.6062, longitude: -122.3321),
            radiusMeters: 450,
            message: "Speakeasy pouring neon cocktails all night.",
            media: .emoji("🍸"),
            metrics: .init(likeCount: 183, commentCount: 22),
            visibility: .friendsOnly,
            createdAt: .init().addingTimeInterval(-7200),
            expiresAt: .init().addingTimeInterval(10 * 3600)
        ),
        .init(
            id: .init(),
            userId: sampleFriends[0].id,
            center: .init(latitude: 47.5952, longitude: -122.3316),
            radiusMeters: 520,
            message: "Local illustrators projecting live sketching.",
            media: .photo(URL(string: "https://images.unsplash.com/photo-1526498460520-4c246339dccb?auto=format&fit=crop&w=900&q=60")!),
            metrics: .init(likeCount: 256, commentCount: 31),
            visibility: .publicAll,
            createdAt: .init().addingTimeInterval(-14_400),
            expiresAt: .init().addingTimeInterval(16 * 3600)
        ),
        .init(
            id: .init(),
            userId: currentUser.id,
            center: .init(latitude: 47.625, longitude: -122.35),
            radiusMeters: 700,
            message: "Stargazing circle sharing telescopes in Gas Works.",
            media: .none,
            metrics: .init(likeCount: 142, commentCount: 19),
            visibility: .friendsOnly,
            createdAt: .init().addingTimeInterval(-18_000),
            expiresAt: .init().addingTimeInterval(20 * 3600)
        ),
        .init(
            id: .init(),
            userId: sampleFriends[3].id,
            center: .init(latitude: 31.2304, longitude: 121.4737),
            radiusMeters: 900,
            message: "Lantern rehearsal on the Bund waterfront.",
            media: .video(
                url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
                poster: URL(string: "https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=900&q=60")
            ),
            metrics: .init(likeCount: 508, commentCount: 76),
            visibility: .publicAll,
            createdAt: .init().addingTimeInterval(-2400),
            expiresAt: .init().addingTimeInterval(18 * 3600)
        ),
        .init(
            id: .init(),
            userId: sampleFriends[0].id,
            center: .init(latitude: 48.8566, longitude: 2.3522),
            radiusMeters: 650,
            message: nil,
            media: .emoji("🥐"),
            metrics: .init(likeCount: 89, commentCount: 7),
            visibility: .friendsOnly,
            createdAt: .init().addingTimeInterval(-26_000),
            expiresAt: .init().addingTimeInterval(22 * 3600)
        ),
        .init(
            id: .init(),
            userId: sampleFriends[1].id,
            center: .init(latitude: -33.8688, longitude: 151.2093),
            radiusMeters: 820,
            message: "Sunrise surf check with free cold brew.",
            media: .photo(URL(string: "https://images.unsplash.com/photo-1507525428034-b723cf961d3e?auto=format&fit=crop&w=900&q=60")!),
            metrics: .init(likeCount: 344, commentCount: 41),
            visibility: .publicAll,
            createdAt: .init().addingTimeInterval(-32_000),
            expiresAt: .init().addingTimeInterval(15 * 3600)
        ),
        .init(
            id: .init(),
            userId: sampleFriends[2].id,
            center: .init(latitude: 35.6895, longitude: 139.6917),
            radiusMeters: 540,
            message: "Night market pop-up swapping vintage game cartridges.",
            media: .none,
            metrics: .init(likeCount: 158, commentCount: 27),
            visibility: .friendsOnly,
            createdAt: .init().addingTimeInterval(-14_400),
            expiresAt: .init().addingTimeInterval(28 * 3600)
        ),
        .init(
            id: .init(),
            userId: sampleFriends[3].id,
            center: .init(latitude: -23.5505, longitude: -46.6333),
            radiusMeters: 780,
            message: "Open-air theater improv under the viaduct.",
            media: .photo(URL(string: "https://images.unsplash.com/photo-1491921125492-f0b52f491f57?auto=format&fit=crop&w=900&q=60")!),
            metrics: .init(likeCount: 261, commentCount: 33),
            visibility: .publicAll,
            createdAt: .init().addingTimeInterval(-21_600),
            expiresAt: .init().addingTimeInterval(26 * 3600)
        ),
        .init(
            id: .init(),
            userId: currentUser.id,
            center: .init(latitude: 55.7558, longitude: 37.6173),
            radiusMeters: 620,
            message: nil,
            media: .emoji("❄️"),
            metrics: .init(likeCount: 103, commentCount: 12),
            visibility: .friendsOnly,
            createdAt: .init().addingTimeInterval(-18_000),
            expiresAt: .init().addingTimeInterval(30 * 3600)
        )
    ]

    static func user(for id: UUID) -> User? {
        if currentUser.id == id {
            return currentUser
        }
        return sampleFriends.first { $0.id == id }
    }
}
