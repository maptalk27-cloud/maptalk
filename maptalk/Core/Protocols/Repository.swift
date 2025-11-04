import Combine

protocol Repository {
    associatedtype Model
    func stream() -> AnyPublisher<[Model], Never>
}

