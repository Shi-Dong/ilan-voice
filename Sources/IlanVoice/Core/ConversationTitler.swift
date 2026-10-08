import Foundation

/// Names a conversation from its latest turns using a small, fast text model
/// (GPT-6 Luna by default) through the OpenAI Responses API.
enum ConversationTitler {
    static let maxLength = 30
    static let turnsConsidered = 10

    private static let instructions = """
    You name chat conversations. Read the transcript and reply with a very \
    concise title of at most \(maxLength) characters that captures what the \
    conversation is about. Reply with the title only: no quotes, no trailing \
    punctuation, no emoji, no prefix such as "Title:".
    """

    /// Returns nil when there is nothing to name or the request fails; the
    /// caller then keeps the current title.
    /// How many times Luna is asked for a shorter title before the app trims it.
    static let shortenAttempts = 2

    static func title(for messages: [Message], apiKey: String, model: String) async -> String? {
        let turns = messages
            .filter { $0.role != .tool && !$0.pending && !$0.text.isEmpty }
            .suffix(turnsConsidered)
        guard !turns.isEmpty, !apiKey.isEmpty else { return nil }
        let transcript = turns
            .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n")

        guard var title = await ask(transcript, apiKey: apiKey, model: model).flatMap(normalize) else { return nil }
        // Too long: ask Luna to rephrase it shorter rather than chopping words off.
        var attempt = 0
        while title.count > maxLength && attempt < shortenAttempts {
            attempt += 1
            let followUp = """
            \(transcript)

            Your title "\(title)" is \(title.count) characters, over the limit of \(maxLength). \
            Write a different, shorter title of at most \(maxLength) characters. Don't cut \
            words off; rephrase or use fewer words.
            """
            guard let shorter = await ask(followUp, apiKey: apiKey, model: model).flatMap(normalize) else { break }
            title = shorter
        }
        return clean(title)
    }

    /// One Responses API call; returns the model's text or nil on failure.
    private static func ask(_ input: String, apiKey: String, model: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "reasoning": ["effort": "none"],
            "max_output_tokens": 40,
            "store": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data

        guard let (reply, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return nil }
        return outputText(obj)
    }

    private static func outputText(_ response: [String: Any]) -> String {
        if let text = response["output_text"] as? String { return text }
        let items = response["output"] as? [[String: Any]] ?? []
        return items
            .filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    /// First line only, without quotes, markdown, a "Title:" prefix or
    /// trailing punctuation. Length is not touched.
    static func normalize(_ raw: String) -> String? {
        var title = raw.split(separator: "\n").first.map(String.init) ?? ""
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*#"))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!:;,").union(.whitespaces))
        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        return title.isEmpty ? nil : title
    }

    /// `normalize`, then the hard length cap on a word boundary: only a last
    /// resort, after Luna has been asked to shorten the title itself.
    static func clean(_ raw: String) -> String? {
        guard var title = normalize(raw) else { return nil }
        if title.count > maxLength {
            let cut = String(title.prefix(maxLength))
            title = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: ",;:-–— ").union(.whitespaces))
        }
        return title.isEmpty ? nil : title
    }
}
