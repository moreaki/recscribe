import Combine
import Foundation
import RecScribeCore
import Security

@MainActor protocol IntelligenceSecretStore {
    func load() throws -> String?
    func save(_ value: String) throws
    func remove() throws
}

/// RecScribe owns this entry. Never imports another app's credentials.
@MainActor struct KeychainIntelligenceSecret: IntelligenceSecretStore {
    private let service: String
    init(service: String = "com.moreaki.recscribe.openai") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key", kSecUseDataProtectionKeychain as String: true]
    }
    func load() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
    func save(_ value: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw SessionError.invalid("RecScribe Keychain operation failed (\(status))") }
    }
}

@MainActor final class IntelligenceCredentials: ObservableObject {
    @Published private(set) var status = "Key status not checked"
    @Published private(set) var models: [String] = []
    @Published private(set) var busy = false
    private let secrets: any IntelligenceSecretStore
    private var task: Task<Void, Never>?
    private let client: IntelligenceClient
    init(secrets: any IntelligenceSecretStore = KeychainIntelligenceSecret(), client: IntelligenceClient = .init()) {
        self.secrets = secrets
        self.client = client
    }

    func key() throws -> Data {
        guard let value = try secrets.load(), !value.isEmpty else { throw SessionError.invalid("Save your OpenAI API key in Settings → Intelligence first") }
        return Data(value.utf8)
    }
    func save(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !key.isEmpty, key.utf8.count <= client.policy.maximumKeyBytes,
              key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { status = "Enter a valid API key"; return }
        do { try secrets.save(key); models = []; status = "Key saved in RecScribe’s Keychain · not tested" }
        catch { status = error.localizedDescription }
    }
    func remove() {
        guard !busy else { return }
        do { try secrets.remove(); models = []; status = "Key removed" }
        catch { status = error.localizedDescription }
    }
    func cancel() { task?.cancel() }
    func test() {
        guard !busy else { return }
        do {
            let key = try key()
            busy = true
            status = "Checking OpenAI model access… No transcript is sent."
            task = Task {
                defer { busy = false; task = nil }
                do {
                    let result = try await client.models(provider: .openai, key: key)
                    try Task.checkCancellation()
                    models = result
                    status = "Connected · \(models.count) candidate text models. Structured Outputs support is checked when generating text."
                } catch is CancellationError { status = "Connection test cancelled" }
                catch { status = error.localizedDescription }
            }
        } catch { status = error.localizedDescription }
    }
}
