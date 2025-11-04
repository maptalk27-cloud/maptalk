import Combine

final class RealViewModel: ObservableObject {
    let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }
}

