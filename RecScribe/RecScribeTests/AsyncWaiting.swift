import Foundation
import Testing

/// Condition waits have an elapsed deadline and report failure at the caller.
/// Negative assertions should first await a positive scheduling/control event.
@MainActor func waitUntil(_ description: String, timeout: Duration = .seconds(10),
                          sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
    let expires = ContinuousClock.now.advanced(by: timeout)
    repeat {
        if condition() { return }
        await Task.yield()
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    } while ContinuousClock.now < expires
    if !condition() { Issue.record("Condition did not become true before the deadline: \(description)", sourceLocation: sourceLocation) }
}
@MainActor func settle() async {
    for _ in 0..<3 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}
