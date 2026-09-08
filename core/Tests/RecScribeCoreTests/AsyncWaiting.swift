import Testing

func expectEventually(timeout: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation,
                      _ predicate: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await predicate(), "Timed out waiting for asynchronous state", sourceLocation: sourceLocation)
}
