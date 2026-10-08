import Foundation

/// Checks an API key against its provider before the app stores it, with a
/// cheap read-only request (listing models) that every valid key may make.
enum APIKeyCheck {
    enum Provider {
        case openAI, gemini

        var name: String { self == .openAI ? "OpenAI" : "Gemini" }
    }

    enum Outcome: Equatable {
        case valid
        case invalid(String)
    }

    static func check(_ key: String, provider: Provider) async -> Outcome {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .invalid("Paste a key first.") }
        var request: URLRequest
        switch provider {
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return .valid
            case 400, 401, 403:
                return .invalid("\(provider.name) rejected this key\(detail(data)).")
            case 429:
                // Over quota or rate-limited, but the key itself was recognised.
                return .valid
            default:
                return .invalid("\(provider.name) answered HTTP \(status)\(detail(data)). Try again in a moment.")
            }
        } catch {
            return .invalid("Couldn't reach \(provider.name): \(error.localizedDescription)")
        }
    }

    /// The provider's own error message, when there is one.
    private static func detail(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = obj["error"] as? [String: Any],
              let message = error["message"] as? String, !message.isEmpty else { return "" }
        let trimmed = String(message.prefix(160)).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return ": " + trimmed
    }

    /// "sk-…a1b2": enough to recognise a key, never enough to use it.
    static func hint(for key: String) -> String {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count > 8 else { return "set" }
        return String(key.prefix(3)) + "…" + String(key.suffix(4))
    }
}
