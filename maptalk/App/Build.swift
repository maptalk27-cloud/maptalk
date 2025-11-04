import Foundation

struct Build {
    enum Configuration {
        case debug
        case release
    }

    struct FeatureFlags: OptionSet {
        let rawValue: Int

        static let mock = FeatureFlags(rawValue: 1 << 0)
        static let prod = FeatureFlags(rawValue: 1 << 1)
    }

    let configuration: Configuration
    let featureFlags: FeatureFlags
}

