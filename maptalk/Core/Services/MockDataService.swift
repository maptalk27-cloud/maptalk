import Foundation

struct MockDataService {
    let currentUser: User = PreviewData.currentUser
    let friends: [User] = PreviewData.sampleFriends
    let ratedPOIs: [RatedPOI] = PreviewData.sampleRatedPOIs
    let reals: [RealPost] = PreviewData.sampleReals
    let pois: [POI] = PreviewData.samplePOIs

    var allUsers: [User] {
        [currentUser] + friends
    }
}
