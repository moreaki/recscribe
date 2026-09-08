//
//  Log.swift
//  RecScribe
//
//  Unified logging via os.Logger. Routes to the system log, retrievable
//  with Console.app or OSLogStore — never a file on the user's Desktop.
//

import Foundation
import os

/// App-wide loggers, grouped by subsystem area.
///
/// Use `.debug`/`.info` for development tracing (not persisted in Release)
/// and `.notice` for aggregate recording timings retained in Release,
/// and `.error` for failures worth diagnosing from a shipped build.
/// Never log on the audio hot path (per-buffer processing).
nonisolated enum Log {
    private static let subsystem = "com.moreaki.recscribe"

    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let recorder = Logger(subsystem: subsystem, category: "recorder")
    static let file = Logger(subsystem: subsystem, category: "file")
    static let permission = Logger(subsystem: subsystem, category: "permission")

    /// Error identity is useful in Release logs; descriptions can contain paths
    /// or other private data and must not be made public to diagnose a failure.
    static func recordFailure(_ error: Error, operation: String) {
        let error = error as NSError
        capture.error("Capture failure operation=\(operation, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code) detail=\(error.localizedDescription, privacy: .private)")
    }
}
