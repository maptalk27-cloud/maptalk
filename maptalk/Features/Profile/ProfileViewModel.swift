import Combine

final class ProfileViewModel: ObservableObject {
    let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }
}

