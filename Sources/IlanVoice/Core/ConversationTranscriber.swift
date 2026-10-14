import Foundation

/// Speech to text for a saved recording, through OpenAI's transcription
/// endpoint. Used after an iPhone conversation, whose turns are not
/// transcribed live.
enum SpeechToText {
    typealias Send = TranscriptFixer.Send

    /// The multipart request for one WAV recording.
    static func request(wav: Data, model: String, prompt: String?, apiKey: String) -> URLRequest {
        let boundary = "ilan-" + UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"turn.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        return request
    }

    /// The transcript, or nil if it failed (retried like Luna's corrections).
    static func transcribe(wav: Data, model: String, prompt: String?, apiKey: String,
                           send: Send = { try await URLSession.shared.data(for: $0) },
                           sleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) async -> String? {
        guard !apiKey.isEmpty else { return nil }
        let request = request(wav: wav, model: model, prompt: prompt, apiKey: apiKey)
        for delay in [0] + TranscriptFixer.retryDelays {
            if delay > 0 { await sleep(delay) }
            do {
                let (data, response) = try await send(request)
                let status = (response as? HTTPURLResponse)?.statusCode
                if status == 200 {
                    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    return (json?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !TranscriptFixer.shouldRetry(status: status, error: nil) { return nil }
            } catch {
                if !TranscriptFixer.shouldRetry(status: nil, error: error) { return nil }
            }
        }
        return nil
    }
}

/// After an iPhone conversation: each of the user's turns is transcribed from
/// its recording, then repaired by Luna (TranscriptFixer) with the dictionary,
/// the conversation so far, and Ilan's replies and tool calls for that turn.
enum ConversationTranscriber {
    /// Transcript as heard (raw) and after Luna's repair (text).
    struct Result: Equatable { var raw: String; var text: String }

    static func finish(_ turnIDs: [String], messages: [Message],
                       audio: (Message) -> Data?,
                       transcribe: (Data, _ context: String?) async -> String?,
                       fix: (_ raw: String, _ history: [Message], _ tools: [Message], _ reply: String) async -> String?)
        async -> [String: Result] {
        var messages = messages
        var results: [String: Result] = [:]
        for id in turnIDs {
            guard let i = messages.firstIndex(where: { $0.id == id }) else { continue }
            let history = Array(messages[..<i])
            let after = messages[(i + 1)...].prefix { $0.role != .user }
            let context = history.last { $0.role == .assistant && !$0.text.isEmpty }?.text
            guard let wav = audio(messages[i]), let raw = await transcribe(wav, context), !raw.isEmpty else {
                results[id] = Result(raw: "", text: "(no words heard)")
                messages[i].text = "(no words heard)"
                continue
            }
            let reply = after.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n")
            let fixed = await fix(raw, history, after.filter { $0.role == .tool }, reply) ?? raw
            results[id] = Result(raw: raw, text: fixed)
            messages[i].text = fixed  // later turns see the repaired text as history
        }
        return results
    }
}
