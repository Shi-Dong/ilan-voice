import Foundation

/// Fixes misheard words in the user's transcript after Ilan has answered.
///
/// The speech-to-text model hears one recording with no idea of the topic,
/// while Ilan hears the raw audio with the whole conversation, so Ilan often
/// understands what the transcript gets wrong. A small text model (the title
/// model, GPT-6 Luna by default) gets the transcript, the user's dictionary,
/// the recent conversation and Ilan's reply, and corrects only what was
/// misheard.
enum TranscriptFixer {
    static let historyTurns = 6

    static let instructions = """
    You correct speech-to-text transcripts of what a user said to a voice assistant. \
    Fix only words, names and terms that were misheard, using the user's vocabulary, \
    the conversation, and the assistant's reply (which shows what the assistant understood). \
    Keep the user's wording, language, style and filler words; don't add, remove, \
    summarise or answer anything. If nothing needs fixing, return the transcript unchanged. \
    Reply with the corrected transcript only.
    """

    /// The user's latest message once it is final and answered, with that answer;
    /// nil while either is still pending or it was already corrected.
    static func turnToCorrect(_ messages: [Message], done: Set<String>) -> (user: Message, reply: Message)? {
        guard let userIndex = messages.lastIndex(where: { $0.role == .user }) else { return nil }
        let user = messages[userIndex]
        guard !user.pending, !user.text.isEmpty, user.rawText == nil, !done.contains(user.id) else { return nil }
        guard let reply = messages[(userIndex + 1)...].first(where: { $0.role == .assistant }),
              !reply.pending, !reply.text.isEmpty else { return nil }
        return (user, reply)
    }

    static func input(_ transcript: String, dictionary: [String], history: [Message], reply: String) -> String {
        var parts: [String] = []
        if !dictionary.isEmpty { parts.append("User's vocabulary: " + dictionary.joined(separator: ", ")) }
        let turns = history.filter { $0.role != .tool && !$0.text.isEmpty }.suffix(historyTurns)
        if !turns.isEmpty {
            parts.append("Conversation so far:\n" + turns.map {
                "\($0.role == .user ? "User" : "Assistant"): \($0.text)"
            }.joined(separator: "\n"))
        }
        parts.append("Transcript to correct:\n" + transcript)
        parts.append("Assistant's reply to it:\n" + reply)
        return parts.joined(separator: "\n\n")
    }

    /// The model's answer if it is a plausible correction, else nil (keep the original).
    static func accept(original: String, corrected raw: String) -> String? {
        let fixed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        guard !fixed.isEmpty, fixed != original else { return nil }
        // A correction changes a few words, not the length of what was said.
        let ratio = Double(fixed.count) / Double(max(original.count, 1))
        guard (0.6...1.6).contains(ratio) || abs(fixed.count - original.count) <= 12 else { return nil }
        return fixed
    }

    static func fix(_ transcript: String, dictionary: [String], history: [Message], reply: String,
                    apiKey: String, model: String) async -> String? {
        guard !apiKey.isEmpty else { return nil }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input(transcript, dictionary: dictionary, history: history, reply: reply),
            "reasoning": ["effort": "none"],
            "max_output_tokens": max(200, transcript.count),
            "store": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        guard let (reply, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return nil }
        let text = (obj["output_text"] as? String) ?? (obj["output"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "message" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["text"] as? String }
            .joined()
        return accept(original: transcript, corrected: text)
    }
}
