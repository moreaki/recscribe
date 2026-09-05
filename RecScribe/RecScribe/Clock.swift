//
//  Clock.swift
//  RecScribe
//
//  Time source for the recording duration timer. Injecting it lets tests
//  advance time deterministically instead of waiting on a real Timer.
//

import Foundation

/// Supplies the current time and a repeating tick for the duration display.
@MainActor
protocol DurationClock: AnyObject {
    var now: Date { get }
    func startTicking(every interval: TimeInterval, onTick: @escaping @MainActor () -> Void)
    func stopTicking()
}

/// Production clock backed by the system clock and a run-loop `Timer`.
@MainActor
final class SystemDurationClock: DurationClock {
    private var timer: Timer?
    private var onTick: (@MainActor () -> Void)?

    var now: Date { Date() }

    func startTicking(every interval: TimeInterval, onTick: @escaping @MainActor () -> Void) {
        stopTicking()
        self.onTick = onTick
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick?() }
        }
    }

    func stopTicking() {
        timer?.invalidate()
        timer = nil
        onTick = nil
    }

    deinit {
        timer?.invalidate()
    }
}
