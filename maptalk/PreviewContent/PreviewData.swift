import CoreLocation
import Foundation

enum PreviewData {
    static let currentUser: User = .init(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE1") ?? UUID(),
        handle: "chengsi",
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
    private static var locationLabels: [UUID: String] = [:]

    struct ChengsiMock {
        let user: User
        let pois: [RatedPOI]
        let reels: [RealPost]
    }

    static let chengsi: ChengsiMock = {
        let referenceDate = Date()
        let aurora = sampleFriends[0]
        let night = sampleFriends[1]
        let skyline = sampleFriends[2]
        let bund = sampleFriends[3]
        let hundredFriends = Array(sampleFriends.prefix(100))
        let megaLikeList = hundredFriends.map(\.id)

        let neonPier = POI(
            id: uuid(7001),
            name: "Neon Pier Park",
            coordinate: .init(latitude: 48.118, longitude: -123.43),
            category: .nightlife
        )
        registerLocationLabel("Port Angeles, Washington, USA", for: neonPier.id)

        let harborStrata = POI(
            id: uuid(7002),
            name: "Harbor Strata Steps",
            coordinate: .init(latitude: 47.658, longitude: -117.426),
            category: .viewpoint
        )
        registerLocationLabel("Spokane, Washington, USA", for: harborStrata.id)

        let chineMarket = POI(
            id: uuid(7003),
            name: "Chine Market Loft",
            coordinate: .init(latitude: 46.602, longitude: -120.505),
            category: .market
        )
        registerLocationLabel("Yakima, Washington, USA", for: chineMarket.id)

        let laRooftop = POI(
            id: uuid(7004),
            name: "Downtown LA Skyline Deck",
            coordinate: .init(latitude: 34.0522, longitude: -118.2437),
            category: .nightlife
        )
        registerLocationLabel("Los Angeles, California, USA", for: laRooftop.id)

        let londonFerry = POI(
            id: uuid(7005),
            name: "Thames Fog Ferry",
            coordinate: .init(latitude: 51.5074, longitude: -0.1278),
            category: .viewpoint
        )
        registerLocationLabel("London, England, UK", for: londonFerry.id)

        let bangkokAlley = POI(
            id: uuid(7006),
            name: "Charoen Alley Projections",
            coordinate: .init(latitude: 13.7563, longitude: 100.5018),
            category: .nightlife
        )
        registerLocationLabel("Bangkok, Thailand", for: bangkokAlley.id)

        let recentFootprint = RatedPOI(
            poi: neonPier,
            highlight: "Clocktower lights pulse every 10 minutes.",
            secondary: "Always dim summer breezes.",
            media: [
                RatedPOI.Media(kind: .photo(URL(string: "https://images.unsplash.com/photo-1498050108023-c5249f4df085?auto=format&fit=crop&w=760&q=60")!))
            ],
            checkIns: [
                RatedPOI.CheckIn(
                    id: uuid(9201),
                    userId: currentUser.id,
                    createdAt: referenceDate.addingTimeInterval(-45 * 60),
                    endorsement: .hype,
                    media: [],
                    tag: .entertainment
                )
            ],
            comments: [],
            endorsements: RatedPOI.EndorsementSummary(hype: 1, solid: 0, meh: 0, questionable: 0),
            tags: [
                RatedPOI.TagStat(tag: .entertainment, count: 3),
                RatedPOI.TagStat(tag: .explore, count: 1)
            ],
            isFavoritedByCurrentUser: true,
            favoritesCount: 21
        )

        let pastFootprint = RatedPOI(
            poi: harborStrata,
            highlight: "Early morning drone loops.",
            secondary: "South steps remain quiet in frost.",
            media: [],
            checkIns: [
                RatedPOI.CheckIn(
                    id: uuid(9202),
                    userId: currentUser.id,
                    createdAt: referenceDate.addingTimeInterval(-40 * 60 * 60),
                    endorsement: .solid,
                    media: [],
                    tag: .explore
                ),
                RatedPOI.CheckIn(
                    id: uuid(9203),
                    userId: currentUser.id,
                    createdAt: referenceDate.addingTimeInterval(-44 * 60 * 60),
                    endorsement: .solid,
                    media: [],
                    tag: .express
                )
            ],
            comments: [],
            endorsements: RatedPOI.EndorsementSummary(hype: 0, solid: 2, meh: 0, questionable: 0),
            tags: [
                RatedPOI.TagStat(tag: .explore, count: 2)
            ],
            isFavoritedByCurrentUser: false,
            favoritesCount: 9
        )

        let marketFootprint = RatedPOI(
            poi: chineMarket,
            highlight: "Market rooftop offers latte flights.",
            secondary: "Sunset salsa happens weekly.",
            media: [
                RatedPOI.Media(kind: .photo(URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=760&q=60")!))
            ],
            checkIns: [
                RatedPOI.CheckIn(
                    id: uuid(9204),
                    userId: currentUser.id,
                    createdAt: referenceDate.addingTimeInterval(-26 * 60 * 60),
                    endorsement: .solid,
                    media: [],
                    tag: .explore
                )
            ],
            comments: [],
            endorsements: RatedPOI.EndorsementSummary(hype: 0, solid: 1, meh: 0, questionable: 0),
            tags: [
                RatedPOI.TagStat(tag: .explore, count: 1)
            ],
            isFavoritedByCurrentUser: true,
            favoritesCount: 5
        )

        let laFootprint = RatedPOI(
            poi: laRooftop,
            highlight: "Rooftop synth loops as the skyline glows.",
            secondary: "Neighbors project gradients onto smog.",
            media: [
                RatedPOI.Media(kind: .photo(URL(string: "https://images.unsplash.com/photo-1477959858617-67f85cf4f1df?auto=format&fit=crop&w=760&q=60")!))
            ],
            checkIns: [
                RatedPOI.CheckIn(
                    id: uuid(9205),
                    userId: currentUser.id,
                    createdAt: referenceDate.addingTimeInterval(-60 * 60 * 24 * 62),
                    endorsement: .hype,
                    media: [],
                    tag: .entertainment
                )
            ],
            comments: [],
            endorsements: RatedPOI.EndorsementSummary(hype: 1, solid: 0, meh: 0, questionable: 0),
            tags: [RatedPOI.TagStat(tag: .entertainment, count: 2)],
            isFavoritedByCurrentUser: true,
            favoritesCount: 18
        )

        let londonFootprint = RatedPOI(
            poi: londonFerry,
            highlight: "Fog lasers turned the ferry deck into vapor.",
            secondary: "Tea bar playlists drift across the river.",
            media: [
                RatedPOI.Media(kind: .photo(URL(string: "https://images.unsplash.com/photo-1505764706515-aa95265c5abc?auto=format&fit=crop&w=760&q=60")!))
            ],
            checkIns: [
                RatedPOI.CheckIn(
                    id: uuid(9206),
                    userId: currentUser.id,
                    createdAt: referenceDate.addingTimeInterval(-60 * 60 * 24 * 68),
                    endorsement: .solid,
                    media: [],
                    tag: .explore
                )
            ],
            comments: [],
            endorsements: RatedPOI.EndorsementSummary(hype: 0, solid: 1, meh: 0, questionable: 0),
            tags: [RatedPOI.TagStat(tag: .explore, count: 1)],
            isFavoritedByCurrentUser: false,
            favoritesCount: 7
        )

        let bangkokFootprint = RatedPOI(
            poi: bangkokAlley,
            highlight: "Tuk-tuk convoy projected pixel art on wet alleys.",
            secondary: "Street vendors synced chimes to the visuals.",
            media: [
                RatedPOI.Media(kind: .photo(URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=760&q=60")!))
            ],
            checkIns: [
                RatedPOI.CheckIn(
                    id: uuid(9207),
                    userId: currentUser.id,
                    createdAt: referenceDate.addingTimeInterval(-60 * 60 * 24 * 74),
                    endorsement: .hype,
                    media: [],
                    tag: .express
                )
            ],
            comments: [],
            endorsements: RatedPOI.EndorsementSummary(hype: 1, solid: 0, meh: 0, questionable: 0),
            tags: [RatedPOI.TagStat(tag: .express, count: 1)],
            isFavoritedByCurrentUser: true,
            favoritesCount: 11
        )

        let droneCountdownReal = RealPost(
            id: uuid(101),
            userId: currentUser.id,
            center: .init(latitude: 47.252, longitude: -122.444),
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
                    relativeTo: referenceDate,
                    replies: [
                        reply(4101, user: skyline, text: "Posting clips later.", minutesAgo: 10, relativeTo: referenceDate),
                        reply(4102, user: bund, text: "Tag me when you do.", minutesAgo: 9, relativeTo: referenceDate)
                    ]
                ),
                comment(
                    3102,
                    user: bund,
                    text: "Need to see that drone swarm IRL.",
                    minutesAgo: 20,
                    relativeTo: referenceDate,
                    replies: [
                        reply(4103, user: night, text: "Bring your long lens.", minutesAgo: 18, relativeTo: referenceDate)
                    ]
                ),
                comment(
                    3103,
                    user: aurora,
                    text: "City soundtrack is unreal tonight.",
                    minutesAgo: 8,
                    relativeTo: referenceDate,
                    replies: [
                        reply(4107, user: currentUser, text: "Capturing audio for later.", minutesAgo: 6, relativeTo: referenceDate)
                    ]
                )
            ],
            visibility: .friendsOnly,
            createdAt: referenceDate.addingTimeInterval(-60 * 60 * 24 * 50),
            expiresAt: referenceDate.addingTimeInterval(-60 * 60 * 24 * 48)
        )
        registerLocationLabel("Tacoma, Washington, USA", for: droneCountdownReal.id)

        let stargazingReal = RealPost(
            id: uuid(106),
            userId: currentUser.id,
            center: .init(latitude: 48.512, longitude: -122.612),
            radiusMeters: 700,
            message: "Stargazing circle sharing telescopes in Gas Works.",
            attachments: [
                .init(id: uuid(1451), kind: .photo(URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=900&q=60")!)),
                .init(id: uuid(1452), kind: .photo(URL(string: "https://images.unsplash.com/photo-1446776653964-20c1d3a81b06?auto=format&fit=crop&w=900&q=60")!))
            ],
            likes: [aurora.id, bund.id, skyline.id, night.id],
            comments: [
                comment(3151, user: skyline, text: "On my way north.", minutesAgo: 92, relativeTo: referenceDate),
                comment(
                    3152,
                    user: bund,
                    text: "Packing extra blankets for everyone.",
                    minutesAgo: 85,
                    relativeTo: referenceDate,
                    replies: [
                        reply(4112, user: currentUser, text: "Appreciate you!", minutesAgo: 83, relativeTo: referenceDate)
                    ]
                )
            ],
            visibility: .friendsOnly,
            createdAt: referenceDate.addingTimeInterval(-60 * 60 * 24 * 55),
            expiresAt: referenceDate.addingTimeInterval(-60 * 60 * 24 * 53)
        )
        registerLocationLabel("Anacortes, Washington, USA", for: stargazingReal.id)

        let moscowReal = RealPost(
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
            likes: [bund.id, night.id, currentUser.id, aurora.id],
            comments: [
                comment(3211, user: aurora, text: "Sending cocoa asap.", minutesAgo: 16, relativeTo: referenceDate),
                comment(3212, user: skyline, text: "Need that snow playlist.", minutesAgo: 12, relativeTo: referenceDate)
            ],
            visibility: .friendsOnly,
            createdAt: referenceDate.addingTimeInterval(-18 * 3600),
            expiresAt: referenceDate.addingTimeInterval(30 * 3600)
        )
        registerLocationLabel("Moscow, Russia", for: moscowReal.id)

        let laGlobalReal = RealPost(
            id: uuid(116),
            userId: currentUser.id,
            center: .init(latitude: 34.0922, longitude: -118.2437),
            radiusMeters: 700,
            message: "Alley rooftop in DTLA beaming synth loops at sunset.",
            attachments: [
                .init(id: uuid(1910), kind: .photo(URL(string: "https://images.unsplash.com/photo-1477959858617-67f85cf4f1df?auto=format&fit=crop&w=1100&q=60")!)),
                .init(id: uuid(1911), kind: .photo(URL(string: "https://images.unsplash.com/photo-1497302347632-904729bc24aa?auto=format&fit=crop&w=1100&q=60")!)),
                .init(id: uuid(1912), kind: .photo(URL(string: "https://images.unsplash.com/photo-1478113988265-ff72cf1161fc?auto=format&fit=crop&w=1100&q=60")!))
            ],
            likes: [currentUser.id, aurora.id, bund.id],
            comments: [
                comment(3220, user: skyline, text: "Muted gold light is insane.", minutesAgo: 32, relativeTo: referenceDate),
                comment(3221, user: bund, text: "Recording the whole set?", minutesAgo: 28, relativeTo: referenceDate)
            ],
            visibility: .publicAll,
            createdAt: referenceDate.addingTimeInterval(-36 * 3600),
            expiresAt: referenceDate.addingTimeInterval(26 * 3600)
        )
        registerLocationLabel("Los Angeles, California, USA", for: laGlobalReal.id)

        let londonGlobalReal = RealPost(
            id: uuid(117),
            userId: currentUser.id,
            center: .init(latitude: 51.5474, longitude: -0.1278),
            radiusMeters: 640,
            message: "River Thames ferry deck turned tea bar. Fog lasers!",
            attachments: [
                .init(id: uuid(1920), kind: .photo(URL(string: "https://images.unsplash.com/photo-1505764706515-aa95265c5abc?auto=format&fit=crop&w=1100&q=60")!)),
                .init(id: uuid(1921), kind: .photo(URL(string: "https://images.unsplash.com/photo-1523419409543-0c1df022bddb?auto=format&fit=crop&w=1100&q=60")!)),
                .init(id: uuid(1922), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=1100&q=60")!)),
                .init(id: uuid(1923), kind: .emoji("☕️"))
            ],
            likes: [night.id, skyline.id, currentUser.id, bund.id],
            comments: [
                comment(3222, user: currentUser, text: "Shipping biscuits from Seattle.", minutesAgo: 44, relativeTo: referenceDate),
                comment(3223, user: night, text: "Need those fog lasers at home.", minutesAgo: 41, relativeTo: referenceDate)
            ],
            visibility: .friendsOnly,
            createdAt: referenceDate.addingTimeInterval(-48 * 3600),
            expiresAt: referenceDate.addingTimeInterval(34 * 3600)
        )
        registerLocationLabel("London, England, UK", for: londonGlobalReal.id)

        let bangkokGlobalReal = RealPost(
            id: uuid(118),
            userId: currentUser.id,
            center: .init(latitude: 13.8063, longitude: 100.5018),
            radiusMeters: 580,
            message: "Bangkok tuk-tuk convoy projecting pixel art on alley walls.",
            attachments: [
                .init(id: uuid(1930), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=1100&q=60")!)),
                .init(id: uuid(1931), kind: .photo(URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=1100&q=60")!)),
                .init(id: uuid(1932), kind: .video(
                    url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!,
                    poster: URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=900&q=60")
                ))
            ],
            likes: [currentUser.id, aurora.id],
            comments: [
                comment(3224, user: bund, text: "Pixel art crew is legendary.", minutesAgo: 52, relativeTo: referenceDate)
            ],
            visibility: .publicAll,
            createdAt: referenceDate.addingTimeInterval(-52 * 3600),
            expiresAt: referenceDate.addingTimeInterval(30 * 3600)
        )
        registerLocationLabel("Bangkok, Thailand", for: bangkokGlobalReal.id)

        let recentReal = RealPost(
            id: uuid(9101),
            userId: currentUser.id,
            center: .init(latitude: 46.065, longitude: -118.343),
            radiusMeters: 520,
            message: "Caught the midnight ferry glow with a film rig.",
            attachments: [
                .init(id: uuid(9102), kind: .photo(URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=900&q=60")!))
            ],
            likes: [currentUser.id, sampleFriends[2].id],
            comments: [
                comment(
                    9103,
                    user: sampleFriends[0],
                    text: "These reflections slay.",
                    minutesAgo: 12,
                    relativeTo: referenceDate
                )
            ],
            visibility: .publicAll,
            createdAt: referenceDate.addingTimeInterval(-60 * 35),
            expiresAt: referenceDate.addingTimeInterval(14 * 3600)
        )
        registerLocationLabel("Walla Walla, Washington, USA", for: recentReal.id)

        let oldReal = RealPost(
            id: uuid(9104),
            userId: currentUser.id,
            center: .init(latitude: 47.596, longitude: -120.661),
            radiusMeters: 640,
            message: "Rewinding the old neon run from last weekend.",
            attachments: [
                .init(id: uuid(9105), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=900&q=60")!))
            ],
            likes: [sampleFriends[1].id, sampleFriends[3].id],
            comments: [
                comment(
                    9106,
                    user: sampleFriends[1],
                    text: "Still gives me chills.",
                    minutesAgo: 60 * 30,
                    relativeTo: referenceDate
                )
            ],
            visibility: .friendsOnly,
            createdAt: referenceDate.addingTimeInterval(-28 * 60 * 60),
            expiresAt: referenceDate.addingTimeInterval(-4 * 3600)
        )
        registerLocationLabel("Leavenworth, Washington, USA", for: oldReal.id)

        let laReal = RealPost(
            id: uuid(9107),
            userId: currentUser.id,
            center: .init(latitude: 34.0122, longitude: -118.2437),
            radiusMeters: 700,
            message: "Alley rooftop in DTLA beaming synth loops at sunset.",
            attachments: [
                .init(id: uuid(9108), kind: .photo(URL(string: "https://images.unsplash.com/photo-1477959858617-67f85cf4f1df?auto=format&fit=crop&w=1100&q=60")!)),
                .init(id: uuid(9109), kind: .photo(URL(string: "https://images.unsplash.com/photo-1497302347632-904729bc24aa?auto=format&fit=crop&w=1100&q=60")!))
            ],
            likes: [sampleFriends[4].id, sampleFriends[5].id],
            comments: [],
            visibility: .publicAll,
            createdAt: referenceDate.addingTimeInterval(-36 * 60 * 60),
            expiresAt: referenceDate.addingTimeInterval(26 * 3600)
        )
        registerLocationLabel("Los Angeles, California, USA", for: laReal.id)

        let londonReal = RealPost(
            id: uuid(9110),
            userId: currentUser.id,
            center: .init(latitude: 51.4674, longitude: -0.1278),
            radiusMeters: 640,
            message: "River Thames ferry deck turned tea bar. Fog lasers!",
            attachments: [
                .init(id: uuid(9111), kind: .photo(URL(string: "https://images.unsplash.com/photo-1505764706515-aa95265c5abc?auto=format&fit=crop&w=1100&q=60")!)),
                .init(id: uuid(9112), kind: .photo(URL(string: "https://images.unsplash.com/photo-1523419409543-0c1df022bddb?auto=format&fit=crop&w=1100&q=60")!)),
                .init(id: uuid(9113), kind: .emoji("☕️"))
            ],
            likes: [sampleFriends[6].id],
            comments: [],
            visibility: .friendsOnly,
            createdAt: referenceDate.addingTimeInterval(-48 * 60 * 60),
            expiresAt: referenceDate.addingTimeInterval(34 * 3600)
        )
        registerLocationLabel("London, England, UK", for: londonReal.id)

        let bangkokReal = RealPost(
            id: uuid(9114),
            userId: currentUser.id,
            center: .init(latitude: 13.7063, longitude: 100.5018),
            radiusMeters: 620,
            message: "Bangkok tuk-tuk convoy projecting pixel art on alley walls.",
            attachments: [
                .init(id: uuid(9115), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=1100&q=60")!)),
                .init(id: uuid(9116), kind: .video(
                    url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!,
                    poster: URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=900&q=60")
                ))
            ],
            likes: [sampleFriends[7].id, sampleFriends[8].id],
            comments: [],
            visibility: .publicAll,
            createdAt: referenceDate.addingTimeInterval(-52 * 60 * 60),
            expiresAt: referenceDate.addingTimeInterval(30 * 3600)
        )
        registerLocationLabel("Bangkok, Thailand", for: bangkokReal.id)

        return ChengsiMock(
            user: currentUser,
            pois: [recentFootprint, marketFootprint, pastFootprint, laFootprint, londonFootprint, bangkokFootprint],
            reels: [
                droneCountdownReal,
                stargazingReal,
                moscowReal,
                laGlobalReal,
                londonGlobalReal,
                bangkokGlobalReal,
                recentReal,
                oldReal
            ]
        )
    }()

    static let sampleRatedPOIs: [RatedPOI] = {
        let referenceDate = Date()

        let waterfront = POI(
            id: UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444") ?? UUID(),
            name: "Kirkland Waterfront",
            coordinate: .init(latitude: 48.754, longitude: -122.478),
            category: .viewpoint
        )
        registerLocationLabel("Bellingham, Washington, USA", for: waterfront.id)

        let cafe = POI(
            id: UUID(uuidString: "BBBBBBBB-5555-6666-7777-888888888888") ?? UUID(),
            name: "Bellevue Roastery",
            coordinate: .init(latitude: 47.037, longitude: -122.9),
            category: .coffee
        )
        registerLocationLabel("Olympia, Washington, USA", for: cafe.id)

        let nightMarket = POI(
            id: UUID(uuidString: "BBBBBBBB-9999-AAAA-BBBB-CCCCCCCCCCCC") ?? UUID(),
            name: "Capitol Hill Night Market",
            coordinate: .init(latitude: 45.638, longitude: -122.661),
            category: .nightlife
        )
        registerLocationLabel("Vancouver, Washington, USA", for: nightMarket.id)

        let artMuseum = POI(
            id: UUID(uuidString: "BBBBBBBB-DDDD-EEEE-FFFF-111111111111") ?? UUID(),
            name: "Bellevue Art Museum",
            coordinate: .init(latitude: 46.852, longitude: -121.76),
            category: .art
        )
        registerLocationLabel("Mount Rainier, Washington, USA", for: artMuseum.id)

        let restaurant = POI(
            id: UUID(uuidString: "BBBBBBBB-1212-3434-5656-787878787878") ?? UUID(),
            name: "Waterfront Bistro",
            coordinate: .init(latitude: 46.28, longitude: -119.277),
            category: .restaurant
        )
        registerLocationLabel("Kennewick, Washington, USA", for: restaurant.id)

        let gasWorks = POI(
            id: UUID(uuidString: "BBBBBBBB-ABAB-CDCD-EFEF-999999999999") ?? UUID(),
            name: "Downtown Park Vista",
            coordinate: .init(latitude: 47.423, longitude: -120.309),
            category: .viewpoint
        )
        registerLocationLabel("Wenatchee, Washington, USA", for: gasWorks.id)

        let capitolCafe = POI(
            id: UUID(uuidString: "BBBBBBBB-A1A1-B2B2-C3C3-D4D4D4D4D4D4") ?? UUID(),
            name: "BelRed Test Kitchen",
            coordinate: .init(latitude: 48.117, longitude: -122.76),
            category: .restaurant
        )
        registerLocationLabel("Port Townsend, Washington, USA", for: capitolCafe.id)

        let redmondMeadow = POI(
            id: UUID(uuidString: "BBBBBBBB-AAAA-FFFF-EEEE-010101010101") ?? UUID(),
            name: "Redmond Meadow Commons",
            coordinate: .init(latitude: 47.673, longitude: -117.239),
            category: .viewpoint
        )
        registerLocationLabel("Spokane, Washington, USA", for: redmondMeadow.id)

        let redmondArcade = POI(
            id: UUID(uuidString: "BBBBBBBB-CECE-FAFA-BCBC-020202020202") ?? UUID(),
            name: "Redmond Retro Arcade",
            coordinate: .init(latitude: 47.6748, longitude: -122.1228),
            category: .nightlife
        )
        registerLocationLabel("Redmond, Washington, USA", for: redmondArcade.id)

        func mediaPhoto(_ url: String) -> RatedPOI.Media {
            RatedPOI.Media(kind: .photo(URL(string: url)!))
        }

        var items: [RatedPOI] = [
            RatedPOI(
                poi: waterfront,
                highlight: nil,
                secondary: nil,
                media: [
                    RatedPOI.Media(
                        kind: .video(
                            url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
                            poster: URL(string: "https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=600&q=60")!
                        )
                    ),
                    mediaPhoto("https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=600&q=60"),
                    mediaPhoto("https://images.unsplash.com/photo-1478720568477-152d9b164e26?auto=format&fit=crop&w=600&q=60")
                ],
                checkIns: [
                    poiCheckIn(
                        6001,
                        user: sampleFriends[0],
                        minutesAgo: 18,
                        relativeTo: referenceDate,
                        endorsement: .hype,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=600&q=60"),
                            mediaPhoto("https://images.unsplash.com/photo-1507525428034-b723cf961d3e?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .explore
                    ),
                    poiCheckIn(
                        6002,
                        user: sampleFriends[3],
                        minutesAgo: 42,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            RatedPOI.Media(
                                kind: .video(
                                    url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
                                    poster: URL(string: "https://images.unsplash.com/photo-1507525428034-b723cf961d3e?auto=format&fit=crop&w=600&q=60")!
                                )
                            ),
                            mediaPhoto("https://images.unsplash.com/photo-1493558103817-58b2924bce98?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .social
                    ),
                    poiCheckIn(
                        6003,
                        user: currentUser,
                        minutesAgo: 64,
                        relativeTo: referenceDate,
                        endorsement: .hype,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=600&q=60"),
                            RatedPOI.Media(
                                kind: .video(
                                    url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!,
                                    poster: URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=600&q=60")!
                                )
                            )
                        ]
                    ),
                    poiCheckIn(
                        6501,
                        user: sampleFriends[9],
                        minutesAgo: 60 * 27,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .detour
                    ),
                    poiCheckIn(
                        6502,
                        user: sampleFriends[10],
                        minutesAgo: 12,
                        relativeTo: referenceDate,
                        media: [],
                        tag: .social
                    )
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
                highlight: "Micro-batch roastery fueling Bellevue's startup core.",
                secondary: "Sunlit patio tucked off 110th Ave NE.",
                media: [
                    RatedPOI.Media(
                        kind: .video(
                            url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!,
                            poster: URL(string: "https://images.unsplash.com/photo-1495474472287-4d71bcdd2085?auto=format&fit=crop&w=600&q=60")!
                        )
                    ),
                    mediaPhoto("https://images.unsplash.com/photo-1509042239860-f550ce710b93?auto=format&fit=crop&w=600&q=60")
                ],
                checkIns: [
                    poiCheckIn(
                        6004,
                        user: sampleFriends[1],
                        minutesAgo: 22,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?auto=format&fit=crop&w=600&q=60"),
                            mediaPhoto("https://images.unsplash.com/photo-1470337458703-46ad1756a187?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .dine
                    ),
                    poiCheckIn(
                        6005,
                        user: sampleFriends[6],
                        minutesAgo: 48,
                        relativeTo: referenceDate,
                        endorsement: .meh,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1481391032119-d89fee407e44?auto=format&fit=crop&w=600&q=60"),
                            RatedPOI.Media(
                                kind: .video(
                                    url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")!,
                                    poster: URL(string: "https://images.unsplash.com/photo-1495474472287-4d71bcdd2085?auto=format&fit=crop&w=600&q=60")!
                                )
                            )
                        ],
                        tag: .study
                    ),
                    poiCheckIn(
                        6503,
                        user: sampleFriends[11],
                        minutesAgo: 60 * 29,
                        relativeTo: referenceDate,
                        endorsement: .hype,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1495474472287-4d71bcdd2085?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .date
                    ),
                    poiCheckIn(
                        6504,
                        user: sampleFriends[12],
                        minutesAgo: 16,
                        relativeTo: referenceDate,
                        media: [],
                        tag: .study
                    )
                ],
                comments: [
                    poiComment(6103, user: sampleFriends[5], content: .text("Wednesday sketch class here—the tutor has killer playlists"), minutesAgo: 35, relativeTo: referenceDate),
                    poiComment(
                        6104,
                        user: currentUser,
                        content: .video(
                            url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4")!,
                            poster: URL(string: "https://images.unsplash.com/photo-1495474472287-4d71bcdd2085?auto=format&fit=crop&w=600&q=60")!
                        ),
                        minutesAgo: 65,
                        relativeTo: referenceDate
                    )
                ],
                endorsements: RatedPOI.EndorsementSummary(hype: 0, solid: 1, meh: 1, questionable: 0),
                tags: [
                    RatedPOI.TagStat(tag: .study, count: 7),
                    RatedPOI.TagStat(tag: .social, count: 5),
                    RatedPOI.TagStat(tag: .dine, count: 4),
                    RatedPOI.TagStat(tag: .date, count: 3)
                ],
                isFavoritedByCurrentUser: false,
                favoritesCount: 12
            ),
            RatedPOI(
                poi: nightMarket,
                highlight: nil,
                secondary: nil,
                media: [
                    RatedPOI.Media(
                        kind: .video(
                            url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")!,
                            poster: URL(string: "https://images.unsplash.com/photo-1489515217757-5fd1be406fef?auto=format&fit=crop&w=600&q=60")!
                        )
                    ),
                    mediaPhoto("https://images.unsplash.com/photo-1498050108023-c5249f4df085?auto=format&fit=crop&w=600&q=60"),
                    mediaPhoto("https://images.unsplash.com/photo-1506157786151-b8491531f063?auto=format&fit=crop&w=600&q=60")
                ],
                checkIns: [
                    poiCheckIn(
                        6006,
                        user: currentUser,
                        minutesAgo: 44,
                        relativeTo: referenceDate,
                        endorsement: .hype,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1521572163474-6864f9cf17ab?auto=format&fit=crop&w=600&q=60"),
                            mediaPhoto("https://images.unsplash.com/photo-1489515217757-5fd1be406fef?auto=format&fit=crop&w=600&q=60"),
                            mediaPhoto("https://images.unsplash.com/photo-1506157786151-b8491531f063?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .entertainment
                    ),
                    poiCheckIn(
                        6007,
                        user: sampleFriends[7],
                        minutesAgo: 70,
                        relativeTo: referenceDate,
                        endorsement: .questionable,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1498050108023-c5249f4df085?auto=format&fit=crop&w=600&q=60"),
                            mediaPhoto("https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .explore
                    ),
                    poiCheckIn(
                        6008,
                        user: sampleFriends[8],
                        minutesAgo: 82,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1497032205916-ac775f0649ae?auto=format&fit=crop&w=600&q=60"),
                            RatedPOI.Media(
                                kind: .video(
                                    url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
                                    poster: URL(string: "https://images.unsplash.com/photo-1475724017904-b712052c192a?auto=format&fit=crop&w=600&q=60")!
                                )
                            )
                        ],
                        tag: .social
                    ),
                    poiCheckIn(
                        6505,
                        user: sampleFriends[13],
                        minutesAgo: 60 * 32,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1506157786151-b8491531f063?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .entertainment
                    ),
                    poiCheckIn(
                        6506,
                        user: sampleFriends[14],
                        minutesAgo: 20,
                        relativeTo: referenceDate,
                        media: [],
                        tag: .explore
                    )
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
                media: [
                    RatedPOI.Media(
                        kind: .video(
                            url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4")!,
                            poster: URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=600&q=60")!
                        )
                    ),
                    mediaPhoto("https://images.unsplash.com/photo-1508921912186-1d1a45ebb3c1?auto=format&fit=crop&w=600&q=60")
                ],
                checkIns: [
                    poiCheckIn(
                        6009,
                        user: sampleFriends[1],
                        minutesAgo: 32,
                        relativeTo: referenceDate,
                        endorsement: .meh,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1487412720507-e7ab37603c6f?auto=format&fit=crop&w=600&q=60"),
                            mediaPhoto("https://images.unsplash.com/photo-1529429617124-aee401f3c21f?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .study
                    ),
                    poiCheckIn(
                        6010,
                        user: sampleFriends[4],
                        minutesAgo: 58,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1508921912186-1d1a45ebb3c1?auto=format&fit=crop&w=600&q=60"),
                            RatedPOI.Media(
                                kind: .video(
                                    url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!,
                                    poster: URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=600&q=60")!
                                )
                            )
                        ],
                        tag: .express
                    ),
                    poiCheckIn(
                        6507,
                        user: sampleFriends[15],
                        minutesAgo: 60 * 34,
                        relativeTo: referenceDate,
                        endorsement: .meh,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1529429617124-aee401f3c21f?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .study
                    ),
                    poiCheckIn(
                        6508,
                        user: sampleFriends[16],
                        minutesAgo: 24,
                        relativeTo: referenceDate,
                        media: [],
                        tag: .explore
                    )
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
                media: [
                    RatedPOI.Media(
                        kind: .video(
                            url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4")!,
                            poster: URL(string: "https://images.unsplash.com/photo-1504674900247-0877df9cc836?auto=format&fit=crop&w=600&q=60")!
                        )
                    ),
                    mediaPhoto("https://images.unsplash.com/photo-1478145046317-39f10e56b5e9?auto=format&fit=crop&w=600&q=60")
                ],
                checkIns: [
                    poiCheckIn(
                        6011,
                        user: sampleFriends[2],
                        minutesAgo: 28,
                        relativeTo: referenceDate,
                        endorsement: .hype,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1478145046317-39f10e56b5e9?auto=format&fit=crop&w=600&q=60"),
                            mediaPhoto("https://images.unsplash.com/photo-1504674900247-0877df9cc836?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .premium
                    ),
                    poiCheckIn(
                        6012,
                        user: sampleFriends[6],
                        minutesAgo: 34,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1514511542842-2a3fb167607d?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .date
                    ),
                    poiCheckIn(
                        6013,
                        user: currentUser,
                        minutesAgo: 56,
                        relativeTo: referenceDate,
                        endorsement: .questionable,
                        media: [
                            RatedPOI.Media(
                                kind: .video(
                                    url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")!,
                                    poster: URL(string: "https://images.unsplash.com/photo-1504674900247-0877df9cc836?auto=format&fit=crop&w=600&q=60")!
                                )
                            )
                        ],
                        tag: .social
                    ),
                    poiCheckIn(
                        6509,
                        user: sampleFriends[17],
                        minutesAgo: 60 * 36,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1478145046317-39f10e56b5e9?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .premium
                    ),
                    poiCheckIn(
                        6510,
                        user: sampleFriends[18],
                        minutesAgo: 30,
                        relativeTo: referenceDate,
                        media: [],
                        tag: .social
                    )
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
            ),
            RatedPOI(
                poi: gasWorks,
                highlight: "Fountain mist catching Bellevue's skyline glow.",
                secondary: "Neighbors sprawl across Downtown Park's lawn terraces.",
                media: [
                    mediaPhoto("https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=600&q=60"),
                    mediaPhoto("https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=600&q=60")
                ],
                checkIns: [
                    poiCheckIn(
                        6511,
                        user: sampleFriends[0],
                        minutesAgo: 25,
                        relativeTo: referenceDate,
                        endorsement: .hype,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1446776811953-b23d57bd21aa?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .explore
                    ),
                    poiCheckIn(
                        6512,
                        user: sampleFriends[5],
                        minutesAgo: 60 * 30,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1491553895911-0055eca6402d?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .unwind
                    )
                ],
                comments: [
                    poiComment(6110, user: sampleFriends[6], content: .text("Projected a laser show onto the waterfall wall last night."), minutesAgo: 33, relativeTo: referenceDate)
                ],
                endorsements: RatedPOI.EndorsementSummary(hype: 1, solid: 1, meh: 0, questionable: 0),
                tags: [
                    RatedPOI.TagStat(tag: .explore, count: 5),
                    RatedPOI.TagStat(tag: .unwind, count: 4),
                    RatedPOI.TagStat(tag: .social, count: 2)
                ],
                isFavoritedByCurrentUser: false,
                favoritesCount: 14
            ),
            RatedPOI(
                poi: capitolCafe,
                highlight: "Experimental test kitchen fueling BelRed's late nights.",
                secondary: "Chef's counter hidden between maker garages.",
                media: [
                    mediaPhoto("https://images.unsplash.com/photo-1495474472287-4d71bcdd2085?auto=format&fit=crop&w=600&q=60")
                ],
                checkIns: [
                    poiCheckIn(
                        6513,
                        user: sampleFriends[3],
                        minutesAgo: 14,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1459257868276-5e65389e2722?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .study
                    ),
                    poiCheckIn(
                        6514,
                        user: sampleFriends[8],
                        minutesAgo: 60 * 52,
                        relativeTo: referenceDate,
                        endorsement: .meh,
                        media: [],
                        tag: .express
                    ),
                    poiCheckIn(
                        6515,
                        user: currentUser,
                        minutesAgo: 60 * 3,
                        relativeTo: referenceDate,
                        endorsement: .hype,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1459257868276-5e65389e2722?auto=format&fit=crop&w=600&q=60"),
                            RatedPOI.Media(kind: .video(url: URL(string: "https://storage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4")!, poster: URL(string: "https://images.unsplash.com/photo-1495474472287-4d71bcdd2085?auto=format&fit=crop&w=600&q=60")!))
                        ],
                        tag: .social
                    )
                ],
                comments: [
                    poiComment(6111, user: sampleFriends[1], content: .text("Synth set + tasting flight this Saturday night!"), minutesAgo: 41, relativeTo: referenceDate),
                    poiComment(6112, user: sampleFriends[4], content: .photo(URL(string: "https://images.unsplash.com/photo-1529429617124-aee401f3c21f?auto=format&fit=crop&w=600&q=60")!), minutesAgo: 90, relativeTo: referenceDate)
                ],
                endorsements: RatedPOI.EndorsementSummary(hype: 1, solid: 1, meh: 1, questionable: 0),
                tags: [
                    RatedPOI.TagStat(tag: .dine, count: 8),
                    RatedPOI.TagStat(tag: .social, count: 6),
                    RatedPOI.TagStat(tag: .study, count: 3)
                ],
                isFavoritedByCurrentUser: true,
                favoritesCount: 18
            ),
            RatedPOI(
                poi: redmondMeadow,
                highlight: "Open-air meadow hugging the Sammamish River trail.",
                secondary: "Families fly drones and kites every weekend.",
                media: [
                    mediaPhoto("https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=600&q=60")
                ],
                checkIns: [
                    poiCheckIn(
                        6516,
                        user: sampleFriends[4],
                        minutesAgo: 60 * 32,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .unwind
                    ),
                    poiCheckIn(
                        6517,
                        user: sampleFriends[7],
                        minutesAgo: 60 * 48,
                        relativeTo: referenceDate,
                        endorsement: .meh,
                        media: [],
                        tag: .detour
                    )
                ],
                comments: [
                    poiComment(6113, user: sampleFriends[2], content: .text("Best place to stretch before a trail ride."), minutesAgo: 60 * 30, relativeTo: referenceDate)
                ],
                endorsements: RatedPOI.EndorsementSummary(hype: 0, solid: 1, meh: 1, questionable: 0),
                tags: [
                    RatedPOI.TagStat(tag: .unwind, count: 6),
                    RatedPOI.TagStat(tag: .explore, count: 4)
                ],
                isFavoritedByCurrentUser: false,
                favoritesCount: 11
            ),
            RatedPOI(
                poi: redmondArcade,
                highlight: "Synthwave arcade tucked under Cleveland Street.",
                secondary: "Quarter night every Thursday.",
                media: [
                    mediaPhoto("https://images.unsplash.com/photo-1503602642458-232111445657?auto=format&fit=crop&w=600&q=60")
                ],
                checkIns: [
                    poiCheckIn(
                        6518,
                        user: sampleFriends[0],
                        minutesAgo: 60 * 40,
                        relativeTo: referenceDate,
                        endorsement: .hype,
                        media: [
                            mediaPhoto("https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=600&q=60")
                        ],
                        tag: .entertainment
                    ),
                    poiCheckIn(
                        6519,
                        user: sampleFriends[6],
                        minutesAgo: 60 * 56,
                        relativeTo: referenceDate,
                        endorsement: .solid,
                        media: [],
                        tag: .social
                    )
                ],
                comments: [
                    poiComment(6114, user: sampleFriends[8], content: .text("DDR tournament bracket still posted from last week."), minutesAgo: 60 * 42, relativeTo: referenceDate)
                ],
                endorsements: RatedPOI.EndorsementSummary(hype: 1, solid: 1, meh: 0, questionable: 0),
                tags: [
                    RatedPOI.TagStat(tag: .entertainment, count: 5),
                    RatedPOI.TagStat(tag: .social, count: 4)
                ],
                isFavoritedByCurrentUser: false,
                favoritesCount: 9
            )
        ]

        return items
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

        var reals: [RealPost] = [
            .init(
                id: uuid(101),
                userId: currentUser.id,
                center: .init(latitude: 47.72, longitude: -117.0),
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
                center: .init(latitude: 47.13, longitude: -119.278),
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
                center: .init(latitude: 47.751, longitude: -120.74),
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
                center: .init(latitude: 45.7, longitude: -122.65),
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
                center: .init(latitude: 48.15, longitude: -123.35),
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
                center: .init(latitude: 48.512, longitude: -122.612),
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
                center: .init(latitude: 47.36, longitude: -122.03),
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
                center: .init(latitude: 46.974, longitude: -123.815),
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
                center: .init(latitude: 46.274, longitude: -119.12),
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
                center: .init(latitude: 55.7958, longitude: 37.6173),
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
            ),
            .init(
                id: uuid(116),
                userId: currentUser.id,
                center: .init(latitude: 34.0522, longitude: -118.1937),
                radiusMeters: 700,
                message: "Alley rooftop in DTLA beaming synth loops at sunset.",
                attachments: [
                    .init(id: uuid(1910), kind: .photo(URL(string: "https://images.unsplash.com/photo-1477959858617-67f85cf4f1df?auto=format&fit=crop&w=1100&q=60")!)),
                    .init(id: uuid(1911), kind: .photo(URL(string: "https://images.unsplash.com/photo-1497302347632-904729bc24aa?auto=format&fit=crop&w=1100&q=60")!)),
                    .init(id: uuid(1912), kind: .photo(URL(string: "https://images.unsplash.com/photo-1478113988265-ff72cf1161fc?auto=format&fit=crop&w=1100&q=60")!))
                ],
                likes: [currentUser.id, aurora.id, bund.id],
                comments: [
                    comment(3220, user: skyline, text: "Muted gold light is insane.", minutesAgo: 32, relativeTo: now),
                    comment(3221, user: bund, text: "Recording the whole set?", minutesAgo: 28, relativeTo: now)
                ],
                visibility: .publicAll,
                createdAt: now.addingTimeInterval(-36_000),
                expiresAt: now.addingTimeInterval(26 * 3600)
            ),
            .init(
                id: uuid(117),
                userId: currentUser.id,
                center: .init(latitude: 51.5074, longitude: -0.1878),
                radiusMeters: 640,
                message: "River Thames ferry deck turned tea bar. Fog lasers!",
                attachments: [
                    .init(id: uuid(1920), kind: .photo(URL(string: "https://images.unsplash.com/photo-1505764706515-aa95265c5abc?auto=format&fit=crop&w=1100&q=60")!)),
                    .init(id: uuid(1921), kind: .photo(URL(string: "https://images.unsplash.com/photo-1523419409543-0c1df022bddb?auto=format&fit=crop&w=1100&q=60")!)),
                    .init(id: uuid(1922), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=1100&q=60")!)),
                    .init(id: uuid(1923), kind: .emoji("☕️"))
                ],
                likes: [night.id, skyline.id, currentUser.id, bund.id],
                comments: [
                    comment(3222, user: currentUser, text: "Shipping biscuits from Seattle.", minutesAgo: 44, relativeTo: now),
                    comment(3223, user: night, text: "Need those fog lasers at home.", minutesAgo: 41, relativeTo: now)
                ],
                visibility: .friendsOnly,
                createdAt: now.addingTimeInterval(-48_000),
                expiresAt: now.addingTimeInterval(34 * 3600)
            ),
            .init(
                id: uuid(118),
                userId: currentUser.id,
                center: .init(latitude: 13.7563, longitude: 100.5618),
                radiusMeters: 580,
                message: "Bangkok tuk-tuk convoy projecting pixel art on alley walls.",
                attachments: [
                    .init(id: uuid(1930), kind: .photo(URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=1100&q=60")!)),
                    .init(id: uuid(1931), kind: .photo(URL(string: "https://images.unsplash.com/photo-1469474968028-56623f02e42e?auto=format&fit=crop&w=1100&q=60")!)),
                    .init(id: uuid(1932), kind: .video(
                        url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!,
                        poster: URL(string: "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=900&q=60")
                    ))
                ],
                likes: [currentUser.id, aurora.id],
                comments: [
                    comment(3224, user: bund, text: "Pixel art crew is legendary.", minutesAgo: 52, relativeTo: now)
                ],
                visibility: .publicAll,
                createdAt: now.addingTimeInterval(-52_000),
                expiresAt: now.addingTimeInterval(30 * 3600)
            )
        ]

        let chengsiIds = Set(chengsi.reels.map(\.id))
        reals.removeAll { chengsiIds.contains($0.id) }
        reals.insert(contentsOf: chengsi.reels, at: 0)
        return reals
    }()

    static func user(for id: UUID) -> User? {
        if currentUser.id == id {
            return currentUser
        }
        return sampleFriends.first { $0.id == id }
    }

    static func locationLabel(for id: UUID) -> String? {
        locationLabels[id]
    }

    private static func registerLocationLabel(_ label: String, for id: UUID) {
        locationLabels[id] = label
    }

    private static func cityLabel(for city: String) -> String {
        switch city {
        case "Hangzhou":
            return "Hangzhou, Zhejiang, China"
        case "Suzhou":
            return "Suzhou, Jiangsu, China"
        case "Seattle":
            return "Seattle, Washington, USA"
        case "Shaanxi":
            return "Xi'an, Shaanxi, China"
        default:
            return city
        }
    }

    static func silentLumenRatedPOIs(referenceDate: Date = Date(), user: User? = nil) -> [RatedPOI] {
        let target = user ?? sampleFriends.first { $0.handle == "silent.lumen" }
        guard let target else { return [] }
        return generatedSilentLumenPOIs(referenceDate: referenceDate, user: target)
    }

    static func silentLumenReals(referenceDate: Date = Date(), user: User? = nil) -> [RealPost] {
        let target = user ?? sampleFriends.first { $0.handle == "silent.lumen" }
        guard let target else { return [] }
        return generatedSilentLumenReals(referenceDate: referenceDate, user: target)
    }

    private static func generatedSilentLumenPOIs(referenceDate: Date, user: User) -> [RatedPOI] {
        let segments: [(String, CLLocationCoordinate2D, Int, Double, Double)] = [
            ("Shaanxi", .init(latitude: 34.341, longitude: 108.939), 25, 365, 270),
            ("Hangzhou", .init(latitude: 30.274, longitude: 120.155), 30, 269, 180),
            ("Suzhou", .init(latitude: 31.298, longitude: 120.583), 20, 179, 95),
            ("Seattle", .init(latitude: 47.6062, longitude: -122.3321), 10, 94, 70),
            ("Suzhou", .init(latitude: 31.298, longitude: 120.583), 15, 69, 0)
        ]
        let categories = POICategory.allCases
        let tags = VisitTag.allCases

        var results: [RatedPOI] = []
        var globalIndex = 0
        for segment in segments {
            let (city, base, count, startDaysAgo, endDaysAgo) = segment
            let locationLabel = cityLabel(for: city)
            for idx in 0..<count {
                let category = categories[globalIndex % categories.count]
                let tag = tags[globalIndex % tags.count]
                let coordinate = jitteredCoordinate(base: base, index: globalIndex, spread: 0.35)
                let visitDate = silentLumenPOIDate(
                    index: idx,
                    count: count,
                    startDaysAgo: startDaysAgo,
                    endDaysAgo: endDaysAgo,
                    referenceDate: referenceDate
                )

                let poi = POI(
                    id: uuid(8000 + globalIndex),
                    name: "Silent \(city) POI \(globalIndex + 1)",
                    coordinate: coordinate,
                    category: category
                )
                registerLocationLabel(locationLabel, for: poi.id)
                let checkIn = RatedPOI.CheckIn(
                    id: uuid(9000 + globalIndex),
                    userId: user.id,
                    createdAt: visitDate,
                    endorsement: .solid,
                    media: [],
                    tag: tag
                )
                let endorsements = RatedPOI.EndorsementSummary(hype: 1, solid: 2, meh: 0, questionable: 0)
                let tagsSummary = [
                    RatedPOI.TagStat(tag: tag, count: 3),
                    RatedPOI.TagStat(tag: .explore, count: 1)
                ]
                let rated = RatedPOI(
                    poi: poi,
                    highlight: "Silent.lumen drop \(city.lowercased()) spot \(globalIndex + 1).",
                    secondary: "Quick log near \(city).",
                    media: [],
                    checkIns: [checkIn],
                    comments: [],
                    endorsements: endorsements,
                    tags: tagsSummary,
                    isFavoritedByCurrentUser: globalIndex.isMultiple(of: 4),
                    favoritesCount: 5 + (globalIndex % 30)
                )
                results.append(rated)
                globalIndex += 1
            }
        }
        return results
    }

    private static func generatedSilentLumenReals(referenceDate: Date, user: User) -> [RealPost] {
        let centers: [(String, CLLocationCoordinate2D, Int)] = [
            ("Hangzhou", .init(latitude: 30.274, longitude: 120.155), 16),
            ("Suzhou", .init(latitude: 31.298, longitude: 120.583), 12),
            ("Shaanxi", .init(latitude: 34.341, longitude: 108.939), 12)
        ]

        var results: [RealPost] = []
        var seed = 12_000
        for (cityOffset, tuple) in centers.enumerated() {
            let (city, base, count) = tuple
            let locationLabel = cityLabel(for: city)
            for idx in 0..<count {
                let global = seed + idx + cityOffset * 100
                let random = pseudoRandom01(index: global, salt: 133)
                let isRecent = random < 0.2
                let created = silentLumenDate(isRecent: isRecent, index: global, referenceDate: referenceDate)
                let coordinate = jitteredCoordinate(base: base, index: idx, spread: 0.6)
                let real = RealPost(
                    id: uuid(global),
                    userId: user.id,
                    center: coordinate,
                    radiusMeters: 420,
                    message: "Silent.lumen \(city) reel \(idx + 1)",
                    attachments: [
                        RealPost.Attachment(id: uuid(global + 5000), kind: .photo(URL(string: "https://images.unsplash.com/photo-1470770841072-f978cf4d019e?auto=format&fit=crop&w=900&q=60")!))
                    ],
                    likes: [],
                    comments: [],
                    visibility: .friendsOnly,
                    createdAt: created,
                    expiresAt: created.addingTimeInterval(30 * 3600)
                )
                registerLocationLabel(locationLabel, for: real.id)
                results.append(real)
            }
            seed += 200
        }
        return results
    }

    private static func jitteredCoordinate(base: CLLocationCoordinate2D, index: Int, spread: Double) -> CLLocationCoordinate2D {
        let salt = pseudoRandomSalt(for: base)
        let angle = 2 * .pi * pseudoRandom01(index: index, salt: salt &+ 1)
        let radius = spread * (0.2 + 0.9 * pseudoRandom01(index: index, salt: salt &+ 2))
        return CLLocationCoordinate2D(
            latitude: base.latitude + sin(angle) * radius,
            longitude: base.longitude + cos(angle) * radius
        )
    }

    private static func pseudoRandom01(index: Int, salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(index &* 1103515245 &+ salt &+ 12345))
        x ^= x >> 11
        x &*= 0x9E3779B97F4A7C15
        x ^= x >> 9
        return Double(x & 0xFFFF_FFFF) / Double(UInt32.max)
    }

    private static func pseudoRandomSalt(for coordinate: CLLocationCoordinate2D) -> Int {
        let latPart = Int((coordinate.latitude * 10_000).rounded())
        let lonPart = Int((coordinate.longitude * 10_000).rounded())
        return latPart ^ lonPart
    }

    private static func silentLumenDate(isRecent: Bool, index: Int, referenceDate: Date) -> Date {
        let dayOffset: Double
        if isRecent {
            // Within this month: scatter between ~1-28 days.
            let scatter = pseudoRandom01(index: index, salt: 211)
            dayOffset = 1.0 + scatter * 27.0
        } else {
            // About a month ago: scatter between ~32-50 days.
            let scatter = pseudoRandom01(index: index, salt: 373)
            dayOffset = 32.0 + scatter * 18.0
        }

        let minutesScatter = pseudoRandom01(index: index, salt: 587) * 12.0 * 60.0 // up to 12 hours
        let totalMinutes = dayOffset * 24.0 * 60.0 + minutesScatter
        return referenceDate.addingTimeInterval(-totalMinutes * 60.0)
    }

    private static func silentLumenPOIDate(
        index: Int,
        count: Int,
        startDaysAgo: Double,
        endDaysAgo: Double,
        referenceDate: Date
    ) -> Date {
        let t = count > 1 ? Double(index) / Double(count - 1) : 0
        let daysAgo = startDaysAgo - (startDaysAgo - endDaysAgo) * t
        let jitterHours = pseudoRandom01(index: index, salt: 733) * 18.0
        let totalSeconds = (daysAgo * 24.0 + jitterHours) * 3600.0
        return referenceDate.addingTimeInterval(-totalSeconds)
    }

    static func profileRatedPOIs(for user: User, customPOIs: [RatedPOI]) -> [RatedPOI] {
        let sanitized: [RatedPOI] = sampleRatedPOIs.compactMap { rated in
            let userVisits = rated.checkIns.filter { $0.userId == user.id }
            guard userVisits.isEmpty == false else { return nil }

            var copy = rated
            copy.checkIns = userVisits
            copy.media = []
            copy.comments = []
            copy.endorsements = RatedPOI.EndorsementSummary(hype: 0, solid: 0, meh: 0, questionable: 0)
            copy.favoritesCount = 0
            copy.isFavoritedByCurrentUser = rated.isFavoritedByCurrentUser
            return copy
        }

        var merged: [UUID: RatedPOI] = [:]
        for rated in sanitized {
            merged[rated.id] = rated
        }
        for custom in customPOIs {
            merged[custom.id] = custom
        }

        return Array(merged.values)
            .sorted { $0.poi.name.localizedCaseInsensitiveCompare($1.poi.name) == .orderedAscending }
    }

    private static func poiCheckIn(
        _ seed: Int,
        user: User,
        minutesAgo: Double,
        relativeTo referenceDate: Date,
        endorsement: RatedPOI.Endorsement? = nil,
        media: [RatedPOI.Media] = [],
        tag: VisitTag? = nil
    ) -> RatedPOI.CheckIn {
        RatedPOI.CheckIn(
            id: uuid(seed),
            userId: user.id,
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
