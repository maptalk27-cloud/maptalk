import Foundation

struct MockDataService {
    let currentUser: User = PreviewData.currentUser
    let friends: [User] = PreviewData.sampleFriends
    let ratedPOIs: [RatedPOI] = PreviewData.sampleRatedPOIs
    let pois: [POI] = PreviewData.samplePOIs
    let ratings: [Rating] = PreviewData.sampleRatings
    let reals: [RealPost] = PreviewData.sampleReals

    var allUsers: [User] {
        [currentUser] + friends
    }
}
