import Foundation
import Testing
import os
@testable import RecScribeCore

private func cancellationPhase(_ value: String) {
    // Direct stderr writes survive a stalled test host without stdout buffering.
    try? FileHandle.standardError.write(contentsOf: Data("Transport cancellation phase: \(value)\n".utf8))
}

private final class SyntheticURLProtocol: URLProtocol, @unchecked Sendable {
    static let activity = OSAllocatedUnfairLock(initialState: (started: 0, stopped: 0))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.activity.withLock { $0.started += 1 }
        if request.url?.lastPathComponent == "wait" {
            cancellationPhase("protocol-started-awaiting-headers")
        }
        guard let url = request.url, url.lastPathComponent != "wait" else { return }
        let code = Int(url.lastPathComponent) ?? 200
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("private-synthetic-response".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.activity.withLock { $0.stopped += 1 }
        if request.url?.lastPathComponent == "wait" {
            cancellationPhase("protocol-stopped")
        }
    }
}

@Suite(.serialized) struct TransportTests {
    private var transport: DirectIntelligenceTransport {
        .init {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SyntheticURLProtocol.self]
            return configuration
        }
    }
    @Test func statusErrorsAndUnknownLengthOversizeNeverExposeBodies() async throws {
        for status in [200, 302, 401, 429, 500] {
            let request = URLRequest(url: URL(string: "http://127.0.0.1/\(status)")!)
            do {
                _ = try await transport.send(request, maximumBytes: 8)
                Issue.record("Expected response rejection")
            } catch {
                #expect(error is CoreFailure)
                #expect(!error.localizedDescription.contains("private-synthetic-response"))
            }
        }
    }
    @Test func cancellationStopsAnInFlightURLSessionRequest() async throws {
        SyntheticURLProtocol.activity.withLock { $0 = (0, 0) }
        let transport = transport
        let task = Task { try await transport.send(URLRequest(url: URL(string: "http://127.0.0.1/wait")!), maximumBytes: 128) }
        defer { task.cancel() }
        cancellationPhase("awaiting-protocol-start")
        try await expectEventually { SyntheticURLProtocol.activity.withLock { $0.started > 0 } }
        cancellationPhase("protocol-start-observed")
        #expect(SyntheticURLProtocol.activity.withLock { $0.started == 1 })
        cancellationPhase("cancel-enter")
        task.cancel()
        cancellationPhase("cancel-returned-awaiting-task")
        await #expect(throws: CancellationError.self) { try await task.value }
        cancellationPhase("task-returned")
        // Foundation finishes cancellation on its delegate queue, after the awaiting task resumes.
        try await expectEventually { SyntheticURLProtocol.activity.withLock { $0.stopped > 0 } }
        cancellationPhase("protocol-stop-observed")
    }
}
