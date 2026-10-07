import Foundation

/// Search engines the built-in `web_search` tool can use. Only Gemini today;
/// the enum leaves room for others.
enum WebSearchProvider: String, CaseIterable, Identifiable {
    case gemini

    var id: String { rawValue }
    var label: String { "Google Gemini (Grounding with Google Search)" }
}

/// The built-in `web_search` tool. GPT-Realtime asks a question; Gemini answers
/// it with Google Search grounding and the app returns the answer plus its
/// sources.
enum WebSearchTool {
    static let functionName = "web_search"
    static let defaultGeminiModel = "gemini-3.6-flash"
    static let maxOutput = 12_000

    static var definition: [String: Any] {
        [
            "type": "function",
            "name": functionName,
            "description": """
            Search the web for current or factual information (news, prices, \
            weather, schedules, documentation, anything after your knowledge \
            cutoff). Returns a short answer grounded in Google Search results, \
            with source titles and links. Phrase the query as a full, specific \
            question. Mention the source when you use the answer.
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to look up, as a specific question."],
                ],
                "required": ["query"],
            ] as [String: Any],
        ]
    }

    static func search(_ query: String, provider: WebSearchProvider, apiKey: String, model: String) async -> String {
        guard !apiKey.isEmpty else {
            return "Error: no web search API key. The user can add a Gemini API key in Settings → Web Search."
        }
        switch provider {
        case .gemini: return await gemini(query, apiKey: apiKey, model: model)
        }
    }

    private static func gemini(_ query: String, apiKey: String, model: String) async -> String {
        let name = model.isEmpty ? defaultGeminiModel : model
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escaped):generateContent") else {
            return "Error: invalid Gemini model name \(name)."
        }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none)
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": """
                Today is \(today). Answer the question using Google Search. Be concise and \
                factual: a few sentences or a short list, with concrete numbers, names and \
                dates. Say so if the results don't answer it.
                """]]],
            "contents": [["role": "user", "parts": [["text": query]]]],
            "tools": [["google_search": [String: Any]()]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return "Error: could not build the request." }
        request.httpBody = data

        let reply: Data
        let response: URLResponse
        do {
            (reply, response) = try await URLSession.shared.data(for: request)
        } catch {
            return "Error: web search failed: \(error.localizedDescription)"
        }
        let obj = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (obj["error"] as? [String: Any])?["message"] as? String
                ?? String(data: reply, encoding: .utf8)?.prefix(300).description ?? "unknown error"
            return "Error: Gemini returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(message)"
        }
        return format(obj)
    }

    /// Answer text, then up to 8 de-duplicated sources.
    static func format(_ response: [String: Any]) -> String {
        let candidate = (response["candidates"] as? [[String: Any]])?.first ?? [:]
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        var answer = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty {
            let reason = candidate["finishReason"] as? String ?? "no answer"
            return "No result from web search (\(reason))."
        }
        let chunks = (candidate["groundingMetadata"] as? [String: Any])?["groundingChunks"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        var sources: [String] = []
        for chunk in chunks {
            guard let web = chunk["web"] as? [String: Any], let uri = web["uri"] as? String else { continue }
            let title = web["title"] as? String ?? uri
            guard seen.insert(title).inserted else { continue }
            sources.append("- \(title): \(uri)")
            if sources.count == 8 { break }
        }
        if answer.count > maxOutput { answer = String(answer.prefix(maxOutput)) + "…" }
        return sources.isEmpty ? answer : answer + "\n\nSources:\n" + sources.joined(separator: "\n")
    }
}
