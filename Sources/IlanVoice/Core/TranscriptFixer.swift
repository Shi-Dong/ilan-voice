import Foundation

/// Fixes misheard words in the user's transcript after Ilan has answered.
///
/// The speech-to-text model hears one recording with no idea of the topic,
/// while Ilan hears the raw audio with the whole conversation, so Ilan often
/// understands what the transcript gets wrong. A small text model (the title
/// model, GPT-6 Luna by default) gets the transcript, the user's dictionary,
/// the recent conversation, the tool calls Ilan made for the message and
/// Ilan's reply, and corrects only what was misheard.
enum TranscriptFixer {
    static let historyTurns = 6

    /// Tool calls shown to the model: at most this many, arguments cut to this length.
    static let maxToolCalls = 8
    static let maxToolArguments = 500

    static let instructions = """
    Your only job is to repair a speech-to-text transcript: find words that the speech \
    recogniser misheard and replace them with what the user actually said. You are not \
    an editor. Do not polish, rephrase, shorten, summarise, translate or answer the \
    message, and do not fix the user's grammar, word choice or style. Keep every word \
    that was heard correctly exactly as it is, in the same order, including filler words, \
    repetitions, false starts and informal phrasing. Change a word only when the evidence \
    shows it was misheard: the user's vocabulary, the conversation, the tool calls the \
    assistant made for this message (their arguments often contain the exact names, \
    paths, commands or terms the user said), and the assistant's reply (which shows \
    what the assistant understood). Spell names and terms as they appear in that \
    evidence. When unsure, leave the word as it is. If nothing was misheard, return the \
    transcript unchanged. Reply with the transcript only, with no quotes, notes or \
    explanations.
    """

    /// One spoken message and everything Ilan did in answer to it.
    struct Turn {
        let user: Message
        /// Ilan's spoken replies in this turn, in order.
        let replies: [Message]
        /// The tool calls Ilan made in this turn, in order.
        let tools: [Message]
    }

    /// The user's latest message once its transcript is final and Ilan's whole
    /// answer to it is done (`turnFinished`: no reply or tool call still
    /// running); nil before that, or when it was already corrected.
    static func turnToCorrect(_ messages: [Message], done: Set<String>, turnFinished: Bool = true) -> Turn? {
        guard turnFinished, let userIndex = messages.lastIndex(where: { $0.role == .user }) else { return nil }
        let user = messages[userIndex]
        guard !user.pending, !user.text.isEmpty, user.rawText == nil, user.typed != true,
              !done.contains(user.id) else { return nil }
        let after = messages[(userIndex + 1)...]
        guard !after.contains(where: \.pending) else { return nil }
        let replies = after.filter { $0.role == .assistant && !$0.text.isEmpty }
        guard !replies.isEmpty else { return nil }
        return Turn(user: user, replies: Array(replies), tools: after.filter { $0.role == .tool })
    }

    /// "name(arguments)", arguments cut to `maxToolArguments` characters.
    static func describe(tool: Message) -> String {
        let name = tool.toolName ?? "tool"
        var args = (tool.toolArguments ?? "{}").trimmingCharacters(in: .whitespacesAndNewlines)
        if args.count > maxToolArguments { args = String(args.prefix(maxToolArguments)) + "…" }
        return "\(name)(\(args))"
    }

    static func input(_ transcript: String, dictionary: [String], history: [Message],
                      tools: [Message] = [], reply: String) -> String {
        var parts: [String] = []
        if !dictionary.isEmpty { parts.append("User's vocabulary: " + dictionary.joined(separator: ", ")) }
        let turns = history.filter { $0.role != .tool && !$0.text.isEmpty }.suffix(historyTurns)
        if !turns.isEmpty {
            parts.append("Conversation so far:\n" + turns.map {
                "\($0.role == .user ? "User" : "Assistant"): \($0.text)"
            }.joined(separator: "\n"))
        }
        parts.append("Transcript to correct:\n" + transcript)
        if !tools.isEmpty {
            parts.append("Tool calls the assistant made for this message:\n"
                         + tools.prefix(maxToolCalls).map { "- " + describe(tool: $0) }.joined(separator: "\n"))
        }
        parts.append("Assistant's reply to it:\n" + reply)
        return parts.joined(separator: "\n\n")
    }

    /// The model's answer with surrounding quotes removed, or nil when it is
    /// empty or unchanged (keep the original). The length of the answer is
    /// not checked: the instructions keep it to a repair, not a rewrite.
    static func accept(original: String, corrected raw: String) -> String? {
        let fixed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fixed.isEmpty, fixed != original else { return nil }
        return fixed
    }

    static func fix(_ transcript: String, dictionary: [String], history: [Message], tools: [Message] = [],
                    reply: String, apiKey: String, model: String) async -> String? {
        guard !apiKey.isEmpty else { return nil }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input(transcript, dictionary: dictionary, history: history, tools: tools, reply: reply),
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
