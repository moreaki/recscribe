import Foundation

/// A lifecycle-owned, injectable poll loop. Generation checks apply after both
/// reads and failures, including readers that do not cooperate with cancellation.
@MainActor
final class JobProgressMonitor {
    static let pollInterval: Duration = .milliseconds(500)
    private let read: @Sendable (URL) async throws -> JobSnapshot
    private let wait: @Sendable () async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(read: @escaping @Sendable (URL) async throws -> JobSnapshot,
         wait: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: JobProgressMonitor.pollInterval) }) {
        self.read = read
        self.wait = wait
    }

    func start(_ manifest: URL, update: @escaping (JobSnapshot) -> Void, failure: @escaping (String) -> Void) {
        stop()
        let id = generation, read = read, wait = wait
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let value = try await read(manifest).validated()
                    guard !Task.isCancelled, self?.generation == id else { return }
                    update(value)
                    if value.state.isTerminal { return }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, self?.generation == id else { return }
                    let fileError = error as NSError
                    // An atomically published manifest may not exist during startup.
                    if fileError.domain != NSCocoaErrorDomain || fileError.code != NSFileReadNoSuchFileError {
                        failure("Cannot read job status: \(error.localizedDescription)")
                    }
                }
                do { try await wait() } catch { return }
            }
        }
    }
    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
    }
    deinit { task?.cancel() }
}
