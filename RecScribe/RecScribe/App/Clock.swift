import Foundation

@MainActor protocol DurationClock: AnyObject {
    var now: Date { get }
    func startTicking(every interval: TimeInterval, onTick: @escaping @MainActor () -> Void)
    func stopTicking()
}

/// One cancellable task supplies presentation ticks. Its callback and generation
/// are owned by MainActor, and a stopped generation cannot deliver a late tick.
@MainActor final class SystemDurationClock: DurationClock {
    private var generation = UUID()
    private var callback: (@MainActor () -> Void)?
    private var ticker: Task<Void, Never>?
    var now: Date { .now }

    func startTicking(every interval: TimeInterval, onTick: @escaping @MainActor () -> Void) {
        stopTicking()
        guard interval.isFinite, interval > 0 else { return }
        callback = onTick
        let identity = generation
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                self?.deliver(for: identity)
            }
        }
    }

    private func deliver(for identity: UUID) {
        if generation == identity { callback?() }
    }

    func stopTicking() {
        generation = UUID()
        ticker?.cancel()
        ticker = nil
        callback = nil
    }

    deinit { ticker?.cancel() }
}

@MainActor protocol PollClock: AnyObject, Sendable {
    func sleep(for interval: TimeInterval) async throws
}

@MainActor final class SystemPollClock: PollClock {
    func sleep(for interval: TimeInterval) async throws {
        guard interval.isFinite else { throw CancellationError() }
        try await Task.sleep(for: .seconds(max(0, interval)))
    }
}
