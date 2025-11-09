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
                        id: uuid(1),
                        userId: sampleFriends[0].id,
                        poiId: waterfront.id,
                        score: 5,
                        emoji: "😎",
                        text: "Sunset vibes!",
                        visibility: .publicAll,
                        createdAt: .init()
                    ),
                    Rating(
                        id: uuid(2),
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
                        id: uuid(3),
                        userId: sampleFriends[1].id,
                        poiId: cafe.id,
                        score: 4,
                        emoji: "☕️",
                        text: "Nitro cold brew hits different.",
                        visibility: .friendsOnly,
                        createdAt: .init().addingTimeInterval(-3600)
                    ),
                    Rating(
                        id: uuid(4),
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
                        id: uuid(5),
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
                        id: uuid(6),
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
                        id: uuid(7),
                        userId: sampleFriends[2].id,
                        poiId: restaurant.id,
                        score: 4,
                        emoji: "🍣",
                        text: "Toro tasting flight worth every credit.",
                        visibility: .friendsOnly,
                        createdAt: .init().addingTimeInterval(-2400)
                    ),
                    Rating(
                        id: uuid(8),
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



    static let sampleReals: [RealPost] = {
        let now = Date()
        let aurora = sampleFriends[0]
        let night = sampleFriends[1]
        let skyline = sampleFriends[2]
        let bund = sampleFriends[3]

        return [
            .init(
                id: uuid(101),
                userId: currentUser.id,
                center: .init(latitude: 47.61, longitude: -122.33),
                radiusMeters: 600,
                message: "Drone light show countdown on Pier 62.",
                attachments: [
                    .init(
                        id: uuid(1101),
                        kind: .video(
                            url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!,
                            poster: URL(string: "https://images.unsplash.com/photo-1534447677768-be436bb09401?auto=format&fit=crop&w=900&q=60")
                        )
                    ),
                    .init(id: uuid(1102), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1103), kind: .photo(URL(string: "https://images.unsplash.com/photo-1478720568477-152d9b164e26?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: [
                    aurora.id,
                    night.id,
                    skyline.id
                ],
                comments: [
                    comment(
                        3101,
                        user: night,
                        text: "Save me a vantage point!",
                        minutesAgo: 14,
                        relativeTo: now,
                        replies: [
                            reply(4101, user: skyline, text: "Posting clips later.", minutesAgo: 10, relativeTo: now),
                            reply(4102, user: bund, text: "Tag me when you do.", minutesAgo: 9, relativeTo: now)
                        ]
                    ),
                    comment(
                        3102,
                        user: bund,
                        text: "Need to see that drone swarm IRL.",
                        minutesAgo: 20,
                        relativeTo: now,
                        replies: [
                            reply(4103, user: night, text: "Bring your long lens.", minutesAgo: 18, relativeTo: now)
                        ]
                    )
                ],
                visibility: .friendsOnly,
                createdAt: now,
                expiresAt: now.addingTimeInterval(24 * 3600)
            ),
            .init(
                id: uuid(102),
                userId: aurora.id,
                center: .init(latitude: 47.62, longitude: -122.21),
                radiusMeters: 600,
                message: "Projection art lighting up the old station.",
                attachments: [
                    .init(id: uuid(1201), kind: .photo(URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1202), kind: .photo(URL(string: "https://images.unsplash.com/photo-1526498460520-4c246339dccb?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1203), kind: .photo(URL(string: "https://images.unsplash.com/photo-1526481280695-3c469df1cb0d?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1204), kind: .photo(URL(string: "https://images.unsplash.com/photo-1452587925148-ce544e77e70d?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1205), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1206), kind: .photo(URL(string: "https://images.unsplash.com/photo-1505761671935-60b3a7427bad?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1207), kind: .photo(URL(string: "https://images.unsplash.com/photo-1519681393784-d120267933ba?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1208), kind: .photo(URL(string: "https://images.unsplash.com/photo-1521737604893-d14cc237f11d?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1209), kind: .photo(URL(string: "https://images.unsplash.com/photo-1529429617124-aee401f3c21f?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: [
                    currentUser.id,
                    skyline.id,
                    bund.id
                ],
                comments: [
                    comment(
                        3111,
                        user: currentUser,
                        text: "I'll bike over after dinner.",
                        minutesAgo: 28,
                        relativeTo: now,
                        replies: [
                            reply(4104, user: skyline, text: "Bring an extra lock.", minutesAgo: 24, relativeTo: now),
                            reply(4105, user: night, text: "Grabbing snacks en route.", minutesAgo: 22, relativeTo: now)
                        ]
                    )
                ],
                visibility: .publicAll,
                createdAt: now.addingTimeInterval(-5_400),
                expiresAt: now.addingTimeInterval(18 * 3600)
            ),
            .init(
                id: uuid(103),
                userId: night.id,
                center: .init(latitude: 47.6185, longitude: -122.342),
                radiusMeters: 600,
                message: "Pop-up street dance class just kicked off.",
                attachments: [],
                likes: [
                    aurora.id,
                    bund.id
                ],
                comments: [
                    comment(3121, user: skyline, text: "Dropping by after work.", minutesAgo: 48, relativeTo: now)
                ],
                visibility: .anonymous,
                createdAt: now.addingTimeInterval(-10_800),
                expiresAt: now.addingTimeInterval(12 * 3600)
            ),
            .init(
                id: uuid(104),
                userId: skyline.id,
                center: .init(latitude: 47.6062, longitude: -122.3321),
                radiusMeters: 450,
                message: "Speakeasy pouring neon cocktails all night.",
                attachments: [
                    .init(id: uuid(1301), kind: .emoji("🍸"))
                ],
                likes: [
                    currentUser.id,
                    aurora.id
                ],
                comments: [
                    comment(3131, user: night, text: "Need the secret knock?", minutesAgo: 30, relativeTo: now)
                ],
                visibility: .friendsOnly,
                createdAt: now.addingTimeInterval(-7_200),
                expiresAt: now.addingTimeInterval(10 * 3600)
            ),
            .init(
                id: uuid(105),
                userId: aurora.id,
                center: .init(latitude: 47.5952, longitude: -122.3316),
                radiusMeters: 520,
                message: "Local illustrators projecting live sketching.",
                attachments: [
                    .init(id: uuid(1401), kind: .photo(URL(string: "https://images.unsplash.com/photo-1498050108023-c5249f4df085?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1402), kind: .photo(URL(string: "https://images.unsplash.com/photo-1517694712202-14dd9538aa97?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: [
                    skyline.id,
                    currentUser.id,
                    night.id
                ],
                comments: [
                    comment(3141, user: bund, text: "Streaming this to the crew.", minutesAgo: 75, relativeTo: now)
                ],
                visibility: .publicAll,
                createdAt: now.addingTimeInterval(-14_400),
                expiresAt: now.addingTimeInterval(16 * 3600)
            ),
            .init(
                id: uuid(106),
                userId: currentUser.id,
                center: .init(latitude: 47.625, longitude: -122.35),
                radiusMeters: 700,
                message: "Stargazing circle sharing telescopes in Gas Works.",
                attachments: [],
                likes: [
                    aurora.id,
                    bund.id
                ],
                comments: [
                    comment(3151, user: skyline, text: "On my way north.", minutesAgo: 92, relativeTo: now)
                ],
                visibility: .friendsOnly,
                createdAt: now.addingTimeInterval(-18_000),
                expiresAt: now.addingTimeInterval(20 * 3600)
            ),
            .init(
                id: uuid(107),
                userId: bund.id,
                center: .init(latitude: 31.2304, longitude: 121.4737),
                radiusMeters: 900,
                message: "Lantern rehearsal on the Bund waterfront.",
                attachments: [
                    .init(
                        id: uuid(1501),
                        kind: .video(
                            url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
                            poster: URL(string: "https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=900&q=60")
                        )
                    ),
                    .init(id: uuid(1502), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=1100&q=60")!))
                ],
                likes: [
                    aurora.id,
                    currentUser.id,
                    night.id
                ],
                comments: [
                    comment(3161, user: skyline, text: "Send more lantern pics!", minutesAgo: 22, relativeTo: now)
                ],
                visibility: .publicAll,
                createdAt: now.addingTimeInterval(-2_400),
                expiresAt: now.addingTimeInterval(18 * 3600)
            ),
            .init(
                id: uuid(108),
                userId: aurora.id,
                center: .init(latitude: 48.8566, longitude: 2.3522),
                radiusMeters: 650,
                message: nil,
                attachments: [
                    .init(id: uuid(1601), kind: .emoji("🥐"))
                ],
                likes: [
                    night.id,
                    bund.id
                ],
                comments: [
                    comment(3171, user: currentUser, text: "Mail me a croissant.", minutesAgo: 60, relativeTo: now)
                ],
                visibility: .friendsOnly,
                createdAt: now.addingTimeInterval(-26_000),
                expiresAt: now.addingTimeInterval(22 * 3600)
            ),
            .init(
                id: uuid(109),
                userId: night.id,
                center: .init(latitude: -33.8688, longitude: 151.2093),
                radiusMeters: 820,
                message: "Sunrise surf check with free cold brew.",
                attachments: [
                    .init(id: uuid(1701), kind: .photo(URL(string: "https://images.unsplash.com/photo-1507525428034-b723cf961d3e?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1702), kind: .photo(URL(string: "https://images.unsplash.com/photo-1493558103817-58b2924bce98?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1703), kind: .photo(URL(string: "https://images.unsplash.com/photo-1494475673543-6a6a27143b22?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: [
                    aurora.id,
                    skyline.id
                ],
                comments: [
                    comment(3181, user: bund, text: "Need that cold brew recipe.", minutesAgo: 68, relativeTo: now)
                ],
                visibility: .publicAll,
                createdAt: now.addingTimeInterval(-32_000),
                expiresAt: now.addingTimeInterval(15 * 3600)
            ),
            .init(
                id: uuid(110),
                userId: skyline.id,
                center: .init(latitude: 35.6895, longitude: 139.6917),
                radiusMeters: 540,
                message: "Night market pop-up swapping vintage game cartridges.",
                attachments: [],
                likes: [
                    currentUser.id,
                    aurora.id,
                    night.id
                ],
                comments: [
                    comment(3191, user: bund, text: "Save a cartridge for me!", minutesAgo: 50, relativeTo: now)
                ],
                visibility: .friendsOnly,
                createdAt: now.addingTimeInterval(-14_400),
                expiresAt: now.addingTimeInterval(28 * 3600)
            ),
            .init(
                id: uuid(111),
                userId: bund.id,
                center: .init(latitude: -23.5505, longitude: -46.6333),
                radiusMeters: 780,
                message: "Open-air theater improv under the viaduct.",
                attachments: [
                    .init(id: uuid(1801), kind: .photo(URL(string: "https://images.unsplash.com/photo-1491921125492-f0b52f491f57?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1802), kind: .photo(URL(string: "https://images.unsplash.com/photo-1542272604-787c3835535d?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1803), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: [
                    aurora.id,
                    skyline.id
                ],
                comments: [
                    comment(
                        3201,
                        user: currentUser,
                        text: "Streaming from Seattle.",
                        minutesAgo: 40,
                        relativeTo: now,
                        replies: [
                            reply(4106, user: aurora, text: "DM the link please!", minutesAgo: 38, relativeTo: now)
                        ]
                    )
                ],
                visibility: .publicAll,
                createdAt: now.addingTimeInterval(-21_600),
                expiresAt: now.addingTimeInterval(26 * 3600)
            ),
            .init(
                id: uuid(112),
                userId: currentUser.id,
                center: .init(latitude: 55.7558, longitude: 37.6173),
                radiusMeters: 620,
                message: nil,
                attachments: [
                    .init(id: uuid(1901), kind: .emoji("❄️"))
                ],
                likes: [
                    bund.id,
                    night.id
                ],
                comments: [
                    comment(3211, user: aurora, text: "Sending cocoa asap.", minutesAgo: 16, relativeTo: now)
                ],
                visibility: .friendsOnly,
                createdAt: now.addingTimeInterval(-18_000),
                expiresAt: now.addingTimeInterval(30 * 3600)
            )
        ]
    }()

    static func user(for id: UUID) -> User? {
        if currentUser.id == id {
            return currentUser
        }
        return sampleFriends.first { $0.id == id }
    }

    private static func uuid(_ seed: Int) -> UUID {
        let formatted = String(format: "00000000-0000-0000-0000-%012d", seed)
        return UUID(uuidString: formatted)!
    }

    private static func comment(
        _ seed: Int,
        user: User,
        text: String,
        minutesAgo: Double,
        relativeTo referenceDate: Date,
        replies: [RealPost.Comment.Reply] = []
    ) -> RealPost.Comment {
        RealPost.Comment(
            id: uuid(seed),
            userId: user.id,
            text: text,
            createdAt: referenceDate.addingTimeInterval(-minutesAgo * 60),
            replies: replies
        )
    }

    private static func reply(
        _ seed: Int,
        user: User,
        text: String,
        minutesAgo: Double,
        relativeTo referenceDate: Date
    ) -> RealPost.Comment.Reply {
        RealPost.Comment.Reply(
            id: uuid(seed),
            userId: user.id,
            text: text,
            createdAt: referenceDate.addingTimeInterval(-minutesAgo * 60)
        )
    }
}
