import Foundation
import Testing
@testable import RecScribeCore

actor MockTransport: IntelligenceTransport {
    var requests: [URLRequest] = []
    let reply: @Sendable (URLRequest) throws -> JSONValue
    init(reply: @escaping @Sendable (URLRequest) throws -> JSONValue) { self.reply = reply }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
        requests.append(request)
        return try reply(request).encoded()
    }
}

@Suite struct IntelligenceTests {
    @Test func cloudDiscoveryIsNativeTextFilteredAndContainsNoTranscript() async throws {
        let transport = MockTransport { _ in ["data": [["id": "chosen-text-model"], ["id": "gpt-realtime-whisper"], ["id": "text-embedding-3-small"], ["id": "chosen-text-model"]]] }
        let models = try await IntelligenceClient(transport: transport).models(provider: .openai, key: Data("synthetic-secret".utf8))
        #expect(models == ["chosen-text-model"])
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-secret")
    }
    @Test func invalidKeysAndCloudWithoutConsentNeverReachTransport() async throws {
        let transport = MockTransport { _ in [:] }
        let client = IntelligenceClient(transport: transport)
        for key in [Data(), Data("bad\nkey".utf8), Data(repeating: 65, count: 2_049)] {
            await #expect(throws: (any Error).self) { try await client.models(provider: .openai, key: key) }
        }
        await #expect(throws: (any Error).self) {
            try await IntelligenceClient(transport: transport).generate(provider: .openai, model: "chosen-text-model", prompt: "synthetic", key: Data("key".utf8), cloudConsent: false)
        }
        #expect(await transport.requests.isEmpty)
    }
    @Test func responsesUsesStrictSchemaNoStorageAndOnlySuppliedText() async throws {
        let transport = MockTransport { _ in ["status": "completed", "output": [["content": [["type": "output_text", "text": "{}"]]]]] }
        let client = IntelligenceClient(transport: transport)
        let raw = try await client.generate(provider: .openai, model: "chosen-text-model", prompt: "synthetic text",
            key: Data("synthetic-secret".utf8), cloudConsent: true)
        #expect(try IntelligenceClient.resultText(raw, provider: .openai) == "{}")
        let request = try #require(await transport.requests.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(body["store"] == false)
        #expect(body["text"]["format"]["strict"] == true)
        #expect(body["text"]["format"]["schema"]["additionalProperties"] == false)
        #expect(body["input"].array?.last?["content"] == "synthetic text")
        #expect(body["audio"] == .null)
        #expect(!String(decoding: try body.encoded(), as: UTF8.self).contains("synthetic-secret"))
    }
    @Test func oversizedJSONIsRejectedEvenWithInjectedTransport() async throws {
        var policy = IntelligencePolicy(); policy.maximumResponseBytes = 8
        let client = IntelligenceClient(transport: MockTransport { _ in ["data": [["id": "too large"]]] }, policy: policy)
        await #expect(throws: (any Error).self) { try await client.models(provider: .openai, key: Data("key".utf8)) }
    }
    @Test func incompleteRefusedAndRemoteOutputRejected() throws {
        for raw: JSONValue in [["status": "incomplete"], ["status": "completed", "output": [["content": [["type": "refusal", "refusal": "private"]]]]]] {
            #expect(throws: (any Error).self) { try IntelligenceClient.resultText(raw, provider: .openai) }
        }
        #expect(throws: (any Error).self) { try IntelligenceClient.resultText(["done": true, "response": "{}", "remote_host": "remote.invalid"], provider: .ollama) }
    }
    @Test func localModelVerificationNeverUsesCloudOrCredentials() async throws {
        let transport = MockTransport { request in
            if request.url?.lastPathComponent == "tags" { return ["models": [["name": "local"], ["name": "cloud-model"], ["name": "remote"]]] }
            let payload = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
            return payload["model"] == "local" ? ["model_info": ["architecture": "synthetic"]] : ["remote_host": "remote.invalid", "model_info": ["architecture": "synthetic"]]
        }
        #expect(try await IntelligenceClient(transport: transport).models(provider: .ollama) == ["local"])
        for request in await transport.requests {
            #expect(request.url?.host() == "127.0.0.1")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }
}
