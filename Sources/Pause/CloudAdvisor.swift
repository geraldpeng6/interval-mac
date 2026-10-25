import Foundation
import Security
import PauseCore

struct CloudAdvice: Decodable { let action: String }
enum CloudError: LocalizedError {
    case invalidEndpoint, missingConfiguration, http(Int), invalidResponse, tooLarge, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "请输入无凭据、无查询参数的 HTTPS chat/completions 地址。"
        case .missingConfiguration: "请填写模型名称并在钥匙串保存 API Key。"
        case .http(let code): "云端返回 HTTP \(code)，已使用本地判断。"
        case .invalidResponse: "云端未返回约定的 allow / defer，已使用本地判断。"
        case .tooLarge: "云端响应过大，已使用本地判断。"
        case .keychain(let status): "钥匙串操作失败（\(status)）。"
        }
    }
}
enum APIKey {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.interval.rest.cloud", kSecAttrAccount as String: "api-key"]
    static func load() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        if value.isEmpty { try delete(); return }
        let data = Data(value.utf8)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(q as CFDictionary, nil)
            guard status == errSecSuccess else { throw CloudError.keychain(status) }
        } else if result != errSecSuccess { throw CloudError.keychain(result) }
    }
    static func delete() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CloudError.keychain(result) }
    }
}

// Redirects are rejected so the bearer token can never move to a different host.
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum CloudAdvisor {
    static func endpoint(_ raw: String) throws -> URL {
        guard let c = URLComponents(string: raw), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.hasSuffix("/chat/completions"), let url = c.url else { throw CloudError.invalidEndpoint }
        return url
    }
    static func ask(preferences p: Preferences, signal: Signal, screenMinutes: Int, activity: Activity) async throws -> CloudAdvice {
        let url = try endpoint(p.cloudEndpoint)
        guard !p.cloudModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let key = APIKey.load(), !key.isEmpty else { throw CloudError.missingConfiguration }
        // This exact aggregate-only payload is also described in the consent UI.
        let summary: [String: Any] = ["screen_minutes": screenMinutes, "keys_per_minute": Int(signal.keysPerMinute), "idle_seconds": Int(min(600, signal.idleSeconds)), "context": p.context.rawValue, "category": signal.category.rawValue, "proposed_activity": activity.rawValue]
        let data = try JSONSerialization.data(withJSONObject: summary, options: .sortedKeys)
        let body: [String: Any] = ["model": p.cloudModel, "messages": [
            ["role": "system", "content": "You advise on timing of a desk break. Return ONLY JSON: {\"action\":\"allow\"} or {\"action\":\"defer\"}. Defer only when the aggregate context strongly suggests interruption. Never prescribe exercises."],
            ["role": "user", "content": String(decoding: data, as: UTF8.self)]
        ], "max_tokens": 40]
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 8
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CloudError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
        var buffer = Data()
        for try await byte in bytes {
            guard buffer.count < 32_768 else { throw CloudError.tooLarge }
            buffer.append(byte)
        }
        return try parse(buffer)
    }
    static func parse(_ buffer: Data) throws -> CloudAdvice {
        struct Envelope: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: buffer)
        guard let content = envelope.choices.first?.message.content.data(using: .utf8), let advice = try? JSONDecoder().decode(CloudAdvice.self, from: content), ["allow", "defer"].contains(advice.action) else { throw CloudError.invalidResponse }
        return advice
    }
}
