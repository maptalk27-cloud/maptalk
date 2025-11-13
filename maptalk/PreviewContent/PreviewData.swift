import CoreLocation
import Foundation

enum PreviewData {
    static let currentUser: User = .init(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1") ?? UUID(),
        handle: "maptalk.me",
        avatarURL: URL(string: "https://images.unsplash.com/photo-1494790108377-be9c29b29330?auto=format&fit=crop&w=200&q=60")
    )

    private static let primaryFriends: [User] = [
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
        ),
        .init(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE6") ?? UUID(),
            handle: "silent.lumen",
            avatarURL: URL(string: "https://images.unsplash.com/photo-1494790108377-be9c29b29330?auto=format&fit=crop&w=200&q=60")
        ),
        .init(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE7") ?? UUID(),
            handle: "lurker.wave",
            avatarURL: URL(string: "https://images.unsplash.com/photo-1525134479668-1bee5c7c6845?auto=format&fit=crop&w=200&q=60")
        ),
        .init(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE8") ?? UUID(),
            handle: "quiet.comet",
            avatarURL: URL(string: "https://images.unsplash.com/photo-1544723795-3fb6469f5b39?auto=format&fit=crop&w=200&q=60")
        ),
        .init(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE9") ?? UUID(),
            handle: "shadow.collector",
            avatarURL: URL(string: "https://images.unsplash.com/photo-1500648767791-00dcc994a43e?auto=format&fit=crop&w=200&q=60")
        )
    ]

    private static let generatedFriends: [User] = (0..<120).map { generatedFriend(index: $0) }

    static let sampleFriends: [User] = primaryFriends + generatedFriends

    static let sampleRatedPOIs: [RatedPOI] = {
        let referenceDate = Date()

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

        func mediaPhoto(_ url: String) -> RatedPOI.Media {
            RatedPOI.Media(kind: .photo(URL(string: url)!))
        }

        func mediaText(_ text: String) -> RatedPOI.Media {
            RatedPOI.Media(kind: .text(text))
        }

        return [
            RatedPOI(
                poi: waterfront,
                highlight: nil,
                secondary: nil,
                media: [],
                checkIns: [
                    poiCheckIn(
                        6001,
                        user: sampleFriends[0],
                        note: "Sunrise stop after the morning ride",
                        minutesAgo: 18,
                        relativeTo: referenceDate,
                        endorsement: .hype,
                        media: [mediaPhoto("https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=600&q=60")],
                        tag: .explore
                    ),
                    poiCheckIn(
                        6002,
                        user: sampleFriends[3],
                        note: "Livestreaming the sunset",
                        minutesAgo: 42,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            RatedPOI.Media(
                                kind: .video(
                                    url: URL(string: "https://example.com/waterfront-live.mp4")!,
                                    poster: URL(string: "https://images.unsplash.com/photo-1507525428034-b723cf961d3e?auto=format&fit=crop&w=600&q=60")!
                                )
                            )
                        ],
                        tag: .social
                    ),
                    poiCheckIn(6003, user: currentUser, note: "Filming + editing a vlog", minutesAgo: 64, relativeTo: referenceDate, endorsement: .hype)
                ],
                comments: [
                    poiComment(6101, user: sampleFriends[2], content: .text("Busker playing city pop tonight—super chill vibes"), minutesAgo: 26, relativeTo: referenceDate),
                    poiComment(6102, user: sampleFriends[5], content: .photo(URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=600&q=60")!), minutesAgo: 58, relativeTo: referenceDate)
                ],
                endorsements: RatedPOI.EndorsementSummary(hype: 2, solid: 1, meh: 0, questionable: 0),
                tags: [
                    RatedPOI.TagStat(tag: .unwind, count: 12),
                    RatedPOI.TagStat(tag: .explore, count: 8),
                    RatedPOI.TagStat(tag: .social, count: 6)
                ],
                isFavoritedByCurrentUser: true,
                favoritesCount: 28
            ),
            RatedPOI(
                poi: cafe,
                highlight: nil,
                secondary: nil,
                media: [],
                checkIns: [
                    poiCheckIn(
                        6004,
                        user: sampleFriends[1],
                        note: "Tiramisu + screenplay session",
                        minutesAgo: 22,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [mediaPhoto("https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?auto=format&fit=crop&w=600&q=60")],
                        tag: .dine
                    ),
                    poiCheckIn(6005, user: sampleFriends[6], note: "Late-night dirty espresso", minutesAgo: 48, relativeTo: referenceDate, endorsement: .meh)
                ],
                comments: [
                    poiComment(6103, user: sampleFriends[5], content: .text("Wednesday sketch class here—the tutor has killer playlists"), minutesAgo: 35, relativeTo: referenceDate),
                    poiComment(6104, user: currentUser, content: .video(url: URL(string: "https://example.com/cafe.mp4")!, poster: URL(string: "https://images.unsplash.com/photo-1495474472287-4d71bcdd2085?auto=format&fit=crop&w=600&q=60")!), minutesAgo: 65, relativeTo: referenceDate)
                ],
                endorsements: RatedPOI.EndorsementSummary(hype: 0, solid: 1, meh: 1, questionable: 0),
                tags: [
                    RatedPOI.TagStat(tag: .dine, count: 6),
                    RatedPOI.TagStat(tag: .study, count: 5),
                    RatedPOI.TagStat(tag: .social, count: 4),
                    RatedPOI.TagStat(tag: .date, count: 3)
                ],
                isFavoritedByCurrentUser: false,
                favoritesCount: 12
            ),
            RatedPOI(
                poi: nightMarket,
                highlight: nil,
                secondary: nil,
                media: [],
                checkIns: [
                    poiCheckIn(
                        6006,
                        user: currentUser,
                        note: "Queued for the limited vinyl pressing",
                        minutesAgo: 44,
                        relativeTo: referenceDate,
                        endorsement: .hype,
                        media: [
                            RatedPOI.Media(kind: .text("Live remix dropping soon"))
                        ],
                        tag: .entertainment
                    ),
                    poiCheckIn(6007, user: sampleFriends[7], note: "Stage lighting is insane", minutesAgo: 70, relativeTo: referenceDate, endorsement: .questionable),
                    poiCheckIn(6008, user: sampleFriends[8], note: "Coming back next week", minutesAgo: 82, relativeTo: referenceDate, endorsement: .solid)
                ],
                comments: [
                    poiComment(6105, user: sampleFriends[2], content: .text("Birria truck in zone B has unreal sauce"), minutesAgo: 52, relativeTo: referenceDate),
                    poiComment(6106, user: sampleFriends[4], content: .photo(URL(string: "https://images.unsplash.com/photo-1521336575822-6da63fb45455?auto=format&fit=crop&w=600&q=60")!), minutesAgo: 78, relativeTo: referenceDate)
                ],
                endorsements: RatedPOI.EndorsementSummary(hype: 1, solid: 1, meh: 0, questionable: 1),
                tags: [
                    RatedPOI.TagStat(tag: .explore, count: 9),
                    RatedPOI.TagStat(tag: .entertainment, count: 8),
                    RatedPOI.TagStat(tag: .social, count: 7),
                    RatedPOI.TagStat(tag: .express, count: 3)
                ],
                isFavoritedByCurrentUser: true,
                favoritesCount: 21
            ),
            RatedPOI(
                poi: artMuseum,
                highlight: nil,
                secondary: nil,
                media: [],
                checkIns: [
                    poiCheckIn(6009, user: sampleFriends[1], note: "Lunch-break sketch session", minutesAgo: 32, relativeTo: referenceDate, endorsement: .meh),
                    poiCheckIn(6010, user: sampleFriends[4], note: "Queued for the immersive exhibit", minutesAgo: 58, relativeTo: referenceDate, endorsement: .solid)
                ],
                comments: [
                    poiComment(6107, user: sampleFriends[0], content: .text("Remember to book the light lab—slots vanish fast"), minutesAgo: 45, relativeTo: referenceDate)
                ],
                endorsements: RatedPOI.EndorsementSummary(hype: 0, solid: 1, meh: 1, questionable: 0),
                tags: [
                    RatedPOI.TagStat(tag: .explore, count: 6),
                    RatedPOI.TagStat(tag: .express, count: 5),
                    RatedPOI.TagStat(tag: .study, count: 3)
                ],
                isFavoritedByCurrentUser: false,
                favoritesCount: 9
            ),
            RatedPOI(
                poi: restaurant,
                highlight: nil,
                secondary: nil,
                media: [],
                checkIns: [
                    poiCheckIn(6011, user: sampleFriends[2], note: "Toro flight is legendary", minutesAgo: 28, relativeTo: referenceDate, endorsement: .hype),
                    poiCheckIn(6012, user: sampleFriends[6], note: "Booked the late seating", minutesAgo: 34, relativeTo: referenceDate, endorsement: .solid),
                    poiCheckIn(6013, user: currentUser, note: "Bringing parents on Friday", minutesAgo: 56, relativeTo: referenceDate, endorsement: .questionable)
                ],
                comments: [
                    poiComment(6108, user: sampleFriends[0], content: .photo(URL(string: "https://images.unsplash.com/photo-1504674900247-0877df9cc836?auto=format&fit=crop&w=600&q=60")!), minutesAgo: 44, relativeTo: referenceDate),
                    poiComment(6109, user: sampleFriends[3], content: .text("Chef remembers names + favorites—make time to chat"), minutesAgo: 61, relativeTo: referenceDate)
                ],
                endorsements: RatedPOI.EndorsementSummary(hype: 1, solid: 1, meh: 0, questionable: 1),
                tags: [
                    RatedPOI.TagStat(tag: .dine, count: 14),
                    RatedPOI.TagStat(tag: .date, count: 8),
                    RatedPOI.TagStat(tag: .premium, count: 6),
                    RatedPOI.TagStat(tag: .social, count: 3)
                ],
                isFavoritedByCurrentUser: true,
                favoritesCount: 34
            )
        ]
    }()

    static var samplePOIs: [POI] {
        sampleRatedPOIs.map(\.poi)
    }

    static let sampleReals: [RealPost] = {
        let now = Date()
        let aurora = sampleFriends[0]
        let night = sampleFriends[1]
        let skyline = sampleFriends[2]
        let bund = sampleFriends[3]
        let hundredFriends = Array(sampleFriends.prefix(100))
        let megaLikeList = hundredFriends.map(\.id)

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
                    .init(id: uuid(1103), kind: .photo(URL(string: "https://images.unsplash.com/photo-1478720568477-152d9b164e26?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1104), kind: .photo(URL(string: "https://images.unsplash.com/photo-1498050108023-c5249f4df085?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: megaLikeList,
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
                    ),
                    comment(
                        3103,
                        user: aurora,
                        text: "City soundtrack is unreal tonight.",
                        minutesAgo: 8,
                        relativeTo: now,
                        replies: [
                            reply(4107, user: currentUser, text: "Capturing audio for later.", minutesAgo: 6, relativeTo: now)
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
                    bund.id,
                    night.id,
                    aurora.id
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
                    ),
                    comment(
                        3112,
                        user: night,
                        text: "Setting up a tripod near the mural.",
                        minutesAgo: 18,
                        relativeTo: now,
                        replies: [
                            reply(4108, user: aurora, text: "Meet me by the north wall.", minutesAgo: 17, relativeTo: now),
                            reply(4109, user: bund, text: "Bringing spare batteries.", minutesAgo: 15, relativeTo: now)
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
                attachments: [
                    .init(id: uuid(1251), kind: .photo(URL(string: "https://images.unsplash.com/photo-1487412720507-e7ab37603c6f?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1252), kind: .photo(URL(string: "https://images.unsplash.com/photo-1508214751196-bcfd4ca60f91?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1253), kind: .photo(URL(string: "https://images.unsplash.com/photo-1437957146754-f6377debe171?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1254), kind: .photo(URL(string: "https://images.unsplash.com/photo-1469478712682-4b91d3e08c21?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: [
                    aurora.id,
                    bund.id,
                    skyline.id,
                    currentUser.id
                ],
                comments: [
                    comment(3121, user: skyline, text: "Dropping by after work.", minutesAgo: 48, relativeTo: now),
                    comment(
                        3122,
                        user: aurora,
                        text: "Playlist is pure fire 🔥",
                        minutesAgo: 42,
                        relativeTo: now,
                        replies: [
                            reply(4110, user: night, text: "Sharing it after class.", minutesAgo: 40, relativeTo: now)
                        ]
                    )
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
                    .init(id: uuid(1301), kind: .emoji("🍸")),
                    .init(id: uuid(1302), kind: .photo(URL(string: "https://images.unsplash.com/photo-1456406644174-8ddd4cd52a06?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1303), kind: .photo(URL(string: "https://images.unsplash.com/photo-1504674900247-0877df9cc836?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1304), kind: .photo(URL(string: "https://images.unsplash.com/photo-1470337458703-46ad1756a187?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: [
                    currentUser.id,
                    aurora.id,
                    night.id,
                    bund.id
                ],
                comments: [
                    comment(3131, user: night, text: "Need the secret knock?", minutesAgo: 30, relativeTo: now),
                    comment(
                        3132,
                        user: aurora,
                        text: "Saving room on the rooftop couch.",
                        minutesAgo: 26,
                        relativeTo: now,
                        replies: [
                            reply(4111, user: skyline, text: "I'll bring neon stir sticks.", minutesAgo: 25, relativeTo: now)
                        ]
                    )
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
                    night.id,
                    bund.id
                ],
                comments: [
                    comment(3141, user: bund, text: "Streaming this to the crew.", minutesAgo: 75, relativeTo: now),
                    comment(
                        3142,
                        user: night,
                        text: "Need those brushes for tomorrow's jam.",
                        minutesAgo: 68,
                        relativeTo: now
                    )
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
                attachments: [
                    .init(id: uuid(1451), kind: .photo(URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1452), kind: .photo(URL(string: "https://images.unsplash.com/photo-1446776653964-20c1d3a81b06?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: [
                    aurora.id,
                    bund.id,
                    skyline.id,
                    night.id
                ],
                comments: [
                    comment(3151, user: skyline, text: "On my way north.", minutesAgo: 92, relativeTo: now),
                    comment(
                        3152,
                        user: bund,
                        text: "Packing extra blankets for everyone.",
                        minutesAgo: 85,
                        relativeTo: now,
                        replies: [
                            reply(4112, user: currentUser, text: "Appreciate you!", minutesAgo: 83, relativeTo: now)
                        ]
                    )
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
                    .init(id: uuid(1502), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=1100&q=60")!)),
                    .init(id: uuid(1503), kind: .photo(URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=1100&q=60")!))
                ],
                likes: [
                    aurora.id,
                    currentUser.id,
                    night.id,
                    skyline.id,
                    bund.id
                ],
                comments: [
                    comment(3161, user: skyline, text: "Send more lantern pics!", minutesAgo: 22, relativeTo: now),
                    comment(
                        3162,
                        user: aurora,
                        text: "Color palette is dreamy.",
                        minutesAgo: 18,
                        relativeTo: now,
                        replies: [
                            reply(4113, user: bund, text: "Will drop RAWs later.", minutesAgo: 16, relativeTo: now)
                        ]
                    )
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
                    .init(id: uuid(1601), kind: .emoji("🥐")),
                    .init(id: uuid(1602), kind: .photo(URL(string: "https://images.unsplash.com/photo-1499636136210-6f4ee915583e?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1603), kind: .photo(URL(string: "https://images.unsplash.com/photo-1482049016688-2d3e1b311543?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: [
                    night.id,
                    bund.id,
                    currentUser.id,
                    skyline.id
                ],
                comments: [
                    comment(3171, user: currentUser, text: "Mail me a croissant.", minutesAgo: 60, relativeTo: now),
                    comment(
                        3172,
                        user: night,
                        text: "Bringing jam jars tomorrow.",
                        minutesAgo: 55,
                        relativeTo: now
                    )
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
                    skyline.id,
                    currentUser.id,
                    night.id
                ],
                comments: [
                    comment(3181, user: bund, text: "Need that cold brew recipe.", minutesAgo: 68, relativeTo: now),
                    comment(
                        3182,
                        user: currentUser,
                        text: "Sending beans from Seattle.",
                        minutesAgo: 64,
                        relativeTo: now,
                        replies: [
                            reply(4114, user: night, text: "Bless!", minutesAgo: 62, relativeTo: now)
                        ]
                    )
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
                attachments: [
                    .init(id: uuid(1751), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1752), kind: .photo(URL(string: "https://images.unsplash.com/photo-1441974231531-c6227db76b6e?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1753), kind: .photo(URL(string: "https://images.unsplash.com/photo-1511910849309-0e77219468ce?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1754), kind: .photo(URL(string: "https://images.unsplash.com/photo-1489515217757-5fd1be406fef?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: [
                    currentUser.id,
                    aurora.id,
                    night.id,
                    skyline.id,
                    bund.id
                ],
                comments: [
                    comment(3191, user: bund, text: "Save a cartridge for me!", minutesAgo: 50, relativeTo: now),
                    comment(
                        3192,
                        user: night,
                        text: "Bringing cables for the retro consoles.",
                        minutesAgo: 46,
                        relativeTo: now
                    )
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
                    skyline.id,
                    currentUser.id,
                    night.id
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
                    ),
                    comment(
                        3202,
                        user: skyline,
                        text: "Crowd looks huge already.",
                        minutesAgo: 35,
                        relativeTo: now
                    )
                ],
                visibility: .publicAll,
                createdAt: now.addingTimeInterval(-21_600),
                expiresAt: now.addingTimeInterval(26 * 3600)
            ),
            .init(
                id: uuid(113),
                userId: aurora.id,
                center: .init(latitude: 47.6036, longitude: -122.3294),
                radiusMeters: 480,
                message: "Neon Alley pop-up tonight: analog synths + incense + zines. Bring earplugs.",
                attachments: [],
                likes: [night.id, skyline.id, currentUser.id],
                comments: [
                    comment(3213, user: night, text: "Dropping by after rehearsal.", minutesAgo: 22, relativeTo: now)
                ],
                visibility: .friendsOnly,
                createdAt: now.addingTimeInterval(-14_400),
                expiresAt: now.addingTimeInterval(22 * 3600)
            ),
            .init(
                id: uuid(114),
                userId: bund.id,
                center: .init(latitude: 47.6219, longitude: -122.3517),
                radiusMeters: 520,
                message: "Skybridge fog rolling in like dry ice. Perfect moment to record footstep Foley.",
                attachments: [],
                likes: [aurora.id, skyline.id],
                comments: [],
                visibility: .publicAll,
                createdAt: now.addingTimeInterval(-10_200),
                expiresAt: now.addingTimeInterval(18 * 3600)
            ),
            .init(
                id: uuid(115),
                userId: skyline.id,
                center: .init(latitude: 47.5952, longitude: -122.3316),
                radiusMeters: 450,
                message: "Quiet watch at the pier. City hum + ferry horns syncing at 68 BPM.",
                attachments: [],
                likes: [currentUser.id, night.id, bund.id, aurora.id],
                comments: [
                    comment(3214, user: currentUser, text: "Looping that rhythm now.", minutesAgo: 9, relativeTo: now)
                ],
                visibility: .friendsOnly,
                createdAt: now.addingTimeInterval(-7_800),
                expiresAt: now.addingTimeInterval(20 * 3600)
            ),
            .init(
                id: uuid(112),
                userId: currentUser.id,
                center: .init(latitude: 55.7558, longitude: 37.6173),
                radiusMeters: 620,
                message: nil,
                attachments: [
                    .init(id: uuid(1901), kind: .emoji("❄️")),
                    .init(id: uuid(1902), kind: .photo(URL(string: "https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=900&q=60")!)),
                    .init(id: uuid(1903), kind: .photo(URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=900&q=60")!))
                ],
                likes: [
                    bund.id,
                    night.id,
                    currentUser.id,
                    aurora.id
                ],
                comments: [
                    comment(3211, user: aurora, text: "Sending cocoa asap.", minutesAgo: 16, relativeTo: now),
                    comment(
                        3212,
                        user: skyline,
                        text: "Need that snow playlist.",
                        minutesAgo: 12,
                        relativeTo: now
                    )
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

    private static func poiCheckIn(
        _ seed: Int,
        user: User,
        note: String?,
        minutesAgo: Double,
        relativeTo referenceDate: Date,
        endorsement: RatedPOI.Endorsement? = nil,
        media: [RatedPOI.Media] = [],
        tag: VisitTag? = nil
    ) -> RatedPOI.CheckIn {
        RatedPOI.CheckIn(
            id: uuid(seed),
            userId: user.id,
            note: note,
            createdAt: referenceDate.addingTimeInterval(-minutesAgo * 60),
            endorsement: endorsement,
            media: media,
            tag: tag
        )
    }

    private static func poiComment(
        _ seed: Int,
        user: User,
        content: RatedPOI.Comment.Content,
        minutesAgo: Double,
        relativeTo referenceDate: Date
    ) -> RatedPOI.Comment {
        RatedPOI.Comment(
            id: uuid(seed),
            userId: user.id,
            content: content,
            createdAt: referenceDate.addingTimeInterval(-minutesAgo * 60)
        )
    }

    private static func generatedFriend(index: Int) -> User {
        let seed = 8000 + index
        let handle = String(format: "pulse%03d.wave", index + 1)
        let avatarURL = URL(string: "https://picsum.photos/seed/pulse\(index + 1)/200")
        return User(id: uuid(seed), handle: handle, avatarURL: avatarURL)
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
