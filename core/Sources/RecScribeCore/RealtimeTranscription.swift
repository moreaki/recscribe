import Foundation

/// Wire limits, not user preferences. Audio is mono signed PCM16, little endian.
public enum RealtimePolicy {
    public static let model = "gpt-realtime-whisper"
    public static let endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    public static let pricing = URL(string: "https://developers.openai.com/api/docs/pricing")!
    public static let privacy = URL(string: "https://developers.openai.com/api/docs/guides/your-data")!
    public static let sampleRate = 24_000
    public static let sampleBytes = 2
    public static let packetFrames = 6_000
    public static let minimumFrames = sampleRate / 10
    public static let maximumSeconds = 30
    public static let maximumEventBytes = 1_024 * 1_024
    public static let maximumTurnBytes = 4 * 1_024 * 1_024
    public static let maximumEvents = 4_096
    public static let timeout: Duration = .seconds(120)
    public static let requestTimeout: TimeInterval = 120
}

public protocol RealtimeSocket: Sendable {
    func send(_ event: JSONValue) async throws
    func receive() async throws -> JSONValue
    func close()
}

/// No redirects, credential storage, proxies, cookies or automatic reconnects.
public final class DirectRealtimeSocket: RealtimeSocket, @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private final class Delegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    public init(key: Data) throws {
        guard !key.isEmpty, key.count <= IntelligencePolicy().maximumKeyBytes,
              let token = String(data: key, encoding: .utf8), !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw CoreFailure("Configure a valid OpenAI key in Settings → Intelligence")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = RealtimePolicy.requestTimeout
        session = URLSession(configuration: configuration, delegate: Delegate(), delegateQueue: nil)
        var request = URLRequest(url: RealtimePolicy.endpoint)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = RealtimePolicy.maximumEventBytes
        socket.resume()
    }
    public func send(_ event: JSONValue) async throws {
        let data = try event.encoded()
        guard data.count <= RealtimePolicy.maximumEventBytes, let text = String(data: data, encoding: .utf8) else {
            throw CoreFailure("Realtime message exceeds the supported limit")
        }
        try await socket.send(.string(text))
    }
    public func receive() async throws -> JSONValue {
        let data: Data
        switch try await socket.receive() {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw CoreFailure("Unsupported Realtime message")
        }
        guard data.count <= RealtimePolicy.maximumEventBytes else { throw CoreFailure("Realtime response is too large") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    public func close() { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    deinit { close() }
}

/// One bounded committed turn per connection: no ambiguous cross-turn ordering,
/// hidden audio backlog, reconnect replay or persistent model context. A future
/// long-lived adapter can implement the same contract after latency measurements.
public struct RealtimeTranscriber: Sendable {
    public struct Result: Sendable {
        public let itemID: String
        public let text: String
        public let audioBytes: Int
        public let elapsedSeconds: Double
        public let firstDeltaSeconds: Double?
    }
    public typealias Factory = @Sendable (Data) throws -> any RealtimeSocket
    private let connect: Factory
    private let timeout: Duration
    public init(timeout: Duration = RealtimePolicy.timeout, connect: @escaping Factory = { try DirectRealtimeSocket(key: $0) }) {
        self.connect = connect; self.timeout = timeout
    }
    public func transcribe(pcm: Data, model: String, language: String?, key: Data, consent: Bool,
                           event: @escaping @Sendable (JSONValue) async throws -> Void = { _ in }) async throws -> Result {
        guard consent else { throw CoreFailure("Cloud audio requires explicit consent for this recording activation") }
        guard model == RealtimePolicy.model else { throw CoreFailure("Unsupported cloud transcription model; no fallback was used") }
        let frames = pcm.count / RealtimePolicy.sampleBytes
        guard pcm.count.isMultiple(of: RealtimePolicy.sampleBytes),
              (RealtimePolicy.minimumFrames...RealtimePolicy.sampleRate * RealtimePolicy.maximumSeconds).contains(frames) else {
            throw CoreFailure("Cloud audio window is outside the supported PCM limits")
        }
        try Task.checkCancellation()
        let socket = try connect(key)
        defer { socket.close() }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Result.self) { group in
                group.addTask { try await self.run(socket, pcm: pcm, model: model, language: language, event: event) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    socket.close()
                    throw CoreFailure("Cloud transcription timed out; recording is unaffected. Enable again to retry with new audio.")
                }
                defer { group.cancelAll(); socket.close() }
                return try await group.next()!
            }
        } onCancel: { socket.close() }
    }
    private func run(_ socket: any RealtimeSocket, pcm: Data, model: String, language: String?,
                     event: @escaping @Sendable (JSONValue) async throws -> Void) async throws -> Result {
        let started = ContinuousClock.now
        var transcription: JSONValue = ["model": .string(model)]
        if let language, !language.isEmpty, language != "auto" { transcription["language"] = .string(language) }
        try await socket.send(["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": .integer(Int64(RealtimePolicy.sampleRate))],
            "transcription": transcription, "turn_detection": nil]]]])
        var ready = false, committedID: String?, completed: [String: String] = [:]
        var firstDelta: Double?, seen: Set<String> = [], receivedBytes = 0
        for _ in 0..<RealtimePolicy.maximumEvents {
            try Task.checkCancellation()
            let value = try await socket.receive()
            receivedBytes += try value.encoded().count
            guard receivedBytes <= RealtimePolicy.maximumTurnBytes else { throw CoreFailure("Cloud response exceeds the turn limit") }
            try await event(value) // Evidence is local; never logged to unified logging.
            if let id = value["event_id"].string, !seen.insert(id).inserted { continue }
            switch value["type"].string {
            case "error", "conversation.item.input_audio_transcription.failed":
                // Provider messages can echo input. Keep the raw event on disk, not in alerts/logs.
                throw CoreFailure("OpenAI rejected this transcription. Check account access, key, model and quota; inspect local raw events. No fallback was used.")
            case "session.updated" where !ready:
                guard value["session"]["type"] == "transcription",
                      value["session"]["audio"]["input"]["transcription"]["model"] == .string(model),
                      value["session"]["audio"]["input"]["format"]["type"] == "audio/pcm",
                      value["session"]["audio"]["input"]["format"]["rate"] == .integer(Int64(RealtimePolicy.sampleRate)),
                      value["session"]["audio"]["input"]["turn_detection"] == .null else {
                    throw CoreFailure("OpenAI did not confirm the requested transcription session; no audio was sent")
                }
                ready = true
                let packetBytes = RealtimePolicy.packetFrames * RealtimePolicy.sampleBytes
                for offset in stride(from: 0, to: pcm.count, by: packetBytes) {
                    try Task.checkCancellation()
                    try await socket.send(["type": "input_audio_buffer.append",
                        "audio": .string(pcm.subdata(in: offset..<min(offset + packetBytes, pcm.count)).base64EncodedString())])
                }
                try await socket.send(["type": "input_audio_buffer.commit"])
            case "input_audio_buffer.committed":
                guard ready, let id = value["item_id"].string, !id.isEmpty, committedID == nil || committedID == id,
                      completed.keys.allSatisfy({ $0 == id }) else {
                    throw CoreFailure("Unexpected cloud turn ordering; review required")
                }
                committedID = id
            case "conversation.item.input_audio_transcription.delta":
                if firstDelta == nil { firstDelta = TextJob.seconds(since: started) }
            case "conversation.item.input_audio_transcription.completed":
                guard let id = value["item_id"].string, let text = value["transcript"].string, completed.count < 2 else {
                    throw CoreFailure("Invalid cloud transcript result")
                }
                guard ready, committedID == nil || committedID == id,
                      completed[id] == nil || completed[id] == text else { throw CoreFailure("Unexpected cloud completion item") }
                completed[id] = text
            default: break
            }
            if let id = committedID, let text = completed[id] {
                return Result(itemID: id, text: text, audioBytes: pcm.count,
                              elapsedSeconds: TextJob.seconds(since: started), firstDeltaSeconds: firstDelta)
            }
        }
        throw CoreFailure("Cloud event limit reached; recording is unaffected")
    }
}
