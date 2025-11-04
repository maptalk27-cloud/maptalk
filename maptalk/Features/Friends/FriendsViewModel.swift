import Combine

final class FriendsViewModel: ObservableObject {
    let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }
}
