import Foundation
import os

/// One policy shared by native clients. These are resource/security bounds, not user paths or model choices.
public struct IntelligencePolicy: Sendable {
    public var requestTimeout: TimeInterval = 180
    public var discoveryTimeout: TimeInterval = 10
    public var maximumResponseBytes = 4 * 1_024 * 1_024
    public var maximumKeyBytes = 2_048
    public var maximumBatchSegments = 24
    public var maximumBatchScalars = 12_000
    public var maximumOutputScalars = 24_000
    public var contextTokens = 8_192
    public var localOutputTokens = 4_096
    public var cloudOutputTokens = 8_192
    public init() {}
}

public protocol IntelligenceTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data
}

/// No shared cookies/cache, automatic redirects, environment proxies or HTTP retries.
/// A streaming read enforces the memory bound even when Content-Length is absent.
public struct DirectIntelligenceTransport: IntelligenceTransport {
    private let configuration: @Sendable () -> URLSessionConfiguration
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
    public init() { configuration = { .ephemeral } }
    init(configuration: @escaping @Sendable () -> URLSessionConfiguration) { self.configuration = configuration }
    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        let configuration = configuration()
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let start = ContinuousClock.now, operation = UUID()
        let logger = Logger(subsystem: "com.moreaki.recscribe", category: "Intelligence")
        defer { logger.notice("Native request id=\(operation) elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw CoreFailure("Invalid AI HTTP response") }
            guard response.statusCode == 200 else {
                // Never surface response bodies, request headers or transcript text in error logs.
                throw CoreFailure("AI request failed (HTTP \(response.statusCode)); no fallback was used")
            }
            guard response.expectedContentLength <= maximumBytes else { throw CoreFailure("AI response exceeds the size limit") }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw CoreFailure("AI response exceeds the size limit") }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if error is CoreFailure { throw error }
            if (error as? URLError)?.code == .timedOut { throw CoreFailure("AI request timed out; no fallback was used") }
            throw CoreFailure("AI connection failed; check the selected service and try again. No fallback was used.")
        }
    }
}
