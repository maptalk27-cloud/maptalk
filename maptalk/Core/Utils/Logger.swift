import os.log

enum Log {
    private static let logger = Logger(subsystem: "com.maptalk.app", category: "app")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

