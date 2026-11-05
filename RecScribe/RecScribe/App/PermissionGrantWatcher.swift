import Foundation

/// A user-started, finite observation session. Each run has an identity so a
/// suspended result from a cancelled run cannot finish a later run.
@MainActor final class PermissionGrantWatcher {
    let kind: PermissionKind
    var onGranted: (() -> Void)?
    private(set) var probeCount = 0
    var isPolling: Bool { run != nil }
    var holdsActivityAssertion: Bool { assertion != nil }
    private let permissions: PermissionProviding
    private let clock: PollClock
    private let interval: TimeInterval
    private let budget: Int
    private var run: UUID?
    private var task: Task<Void, Never>?
    private var announced = false
    nonisolated(unsafe) private var assertion: NSObjectProtocol?

    init(kind: PermissionKind = .screenCapture, permissions: PermissionProviding,
         clock: PollClock? = nil, interval: TimeInterval = 1, maxProbes: Int = 600) {
        self.kind = kind
        self.permissions = permissions
        self.clock = clock ?? SystemPollClock()
        self.interval = interval
        budget = max(0, maxProbes)
    }

    func startPolling() {
        guard run == nil, !announced, budget > 0 else { return }
        let identity = UUID()
        run = identity
        assertion = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                          reason: "Observing the recording permission requested by the user")
        let clock = clock, interval = interval, budget = budget
        task = Task { [weak self] in
            for index in 0..<budget {
                guard !Task.isCancelled, await self?.probe(run: identity) == true else { return }
                if index + 1 < budget {
                    do { try await clock.sleep(for: interval) }
                    catch { self?.finish(run: identity); return }
                }
            }
            self?.finish(run: identity)
        }
    }

    func stopPolling() {
        run = nil
        task?.cancel()
        task = nil
        if let token = assertion {
            assertion = nil
            ProcessInfo.processInfo.endActivity(token)
        }
    }

    func probeOnce() async {
        probeCount += 1
        let answer = await permissions.checkPermission(kind)
        accept(answer)
    }

    private func probe(run identity: UUID) async -> Bool {
        guard run == identity else { return false }
        probeCount += 1
        let answer = await permissions.checkPermission(kind)
        guard run == identity, !Task.isCancelled else { return false }
        accept(answer)
        return run == identity
    }

    private func accept(_ answer: PermissionStatus) {
        guard answer == .granted, !announced else { return }
        announced = true
        stopPolling()
        onGranted?()
    }

    private func finish(run identity: UUID) {
        if run == identity { stopPolling() }
    }

    deinit {
        task?.cancel()
        if let token = assertion { ProcessInfo.processInfo.endActivity(token) }
    }
}
