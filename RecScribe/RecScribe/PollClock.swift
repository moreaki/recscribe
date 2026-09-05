//
//  PollClock.swift
//  RecScribe
//
//  The wait between permission probes, injectable so tests never sleep.
//
//  Separate from `DurationClock` on purpose: that one drives a repeating tick for
//  the recording timer, whereas polling needs to *await* each interval so the next
//  probe can't start before the previous one finishes.
//

import Foundation

@MainActor
protocol PollClock: AnyObject, Sendable {
    /// Suspends for `interval`. Throws `CancellationError` if the surrounding
    /// task is cancelled while waiting.
    func sleep(for interval: TimeInterval) async throws
}

@MainActor
final class SystemPollClock: PollClock {
    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}
