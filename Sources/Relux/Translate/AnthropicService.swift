import Foundation
import os
import Security

private let log = Logger(subsystem: "com.relux.app", category: "anthropic")

enum KeychainHelper {
    private static let service = "com.relux.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class AnthropicService {
    static let defaultModel = "claude-sonnet-4-20250514"

    static let defaultSystemPrompt = """
    You are a translation machine. Translate the user's text into {target_language}. \
    Output ONLY the translated text with no additions whatsoever. \
    No preamble, no explanation, no quotation marks, no markdown, no notes. \
    Preserve original formatting including line breaks and whitespace. \
    If the text is already in {target_language}, output it unchanged.
    """

    private var apiKey: String? {
        KeychainHelper.load(key: "anthropicApiKey")
    }

    var model: String {
        UserDefaults.standard.string(forKey: "translateModel") ?? Self.defaultModel
    }

    var systemPrompt: String {
        UserDefaults.standard.string(forKey: "translateSystemPrompt") ?? Self.defaultSystemPrompt
    }

    func translate(text: String, targetLanguage: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let apiKey = await apiKey
                    let model = await model
                    let systemPrompt = await systemPrompt

                    guard let apiKey, !apiKey.isEmpty else {
                        continuation.yield("[Error: Anthropic API key not set. Configure it in Settings → Translate.]")
                        continuation.finish()
                        return
                    }

                    let resolvedPrompt = systemPrompt.replacingOccurrences(of: "{target_language}", with: targetLanguage)

                    let url = URL(string: "https://api.anthropic.com/v1/messages")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")

                    let body: [String: Any] = [
                        "model": model,
                        "max_tokens": 4096,
                        "stream": true,
                        "system": resolvedPrompt,
                        "messages": [
                            ["role": "user", "content": text],
                        ],
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        continuation.yield("[Error \(httpResponse.statusCode): \(errorBody)]")
                        continuation.finish()
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        if json == "[DONE]" { break }

                        guard let data = json.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String else { continue }

                        if type == "content_block_delta",
                           let delta = event["delta"] as? [String: Any],
                           let text = delta["text"] as? String
                        {
                            continuation.yield(text)
                        }
                    }
                } catch {
                    log.error("Translation failed: \(error.localizedDescription)")
                    continuation.yield("[Error: \(error.localizedDescription)]")
                }
                continuation.finish()
            }
        }
    }
}
