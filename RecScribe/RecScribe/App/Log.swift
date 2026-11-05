import Foundation
import os

nonisolated enum Log {
    private static func logger(_ area: String) -> Logger {
        Logger(subsystem: "com.moreaki.recscribe", category: area)
    }
    static let capture = logger("capture")
    static let recorder = logger("recorder")
    static let file = logger("file")
    static let permission = logger("permission")

    static func recordFailure(_ failure: Error, operation: String) {
        let value = failure as NSError
        capture.error("Capture failure operation=\(operation, privacy: .public) domain=\(value.domain, privacy: .public) code=\(value.code) detail=\(value.localizedDescription, privacy: .private)")
    }
}
