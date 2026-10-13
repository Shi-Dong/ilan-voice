import Foundation

/// Tokens one API call used, as OpenAI reported them. Cached tokens are part
/// of the input (and cheaper); audio and text are priced differently.
struct TokenUsage: Codable, Equatable {
    var textInput = 0
    var audioInput = 0
    var cachedTextInput = 0
    var cachedAudioInput = 0
    var textOutput = 0
    var audioOutput = 0

    var input: Int { textInput + audioInput }
    var cachedInput: Int { cachedTextInput + cachedAudioInput }
    var output: Int { textOutput + audioOutput }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(textInput: a.textInput + b.textInput, audioInput: a.audioInput + b.audioInput,
                   cachedTextInput: a.cachedTextInput + b.cachedTextInput,
                   cachedAudioInput: a.cachedAudioInput + b.cachedAudioInput,
                   textOutput: a.textOutput + b.textOutput, audioOutput: a.audioOutput + b.audioOutput)
    }

    private static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    /// A Realtime `response.done` usage object:
    /// input_token_details {text_tokens, audio_tokens, cached_tokens_details {text_tokens, audio_tokens}}
    /// and output_token_details {text_tokens, audio_tokens}.
    static func realtime(_ usage: [String: Any]) -> TokenUsage {
        let input = usage["input_token_details"] as? [String: Any] ?? [:]
        let cached = input["cached_tokens_details"] as? [String: Any] ?? [:]
        let output = usage["output_token_details"] as? [String: Any] ?? [:]
        var u = TokenUsage(textInput: int(input["text_tokens"]), audioInput: int(input["audio_tokens"]),
                           cachedTextInput: int(cached["text_tokens"]), cachedAudioInput: int(cached["audio_tokens"]),
                           textOutput: int(output["text_tokens"]), audioOutput: int(output["audio_tokens"]))
        // No breakdown given: count everything as text so nothing is lost.
        if u.input == 0 { u.textInput = int(usage["input_tokens"]) }
        if u.output == 0 { u.textOutput = int(usage["output_tokens"]) }
        if u.cachedInput == 0 { u.cachedTextInput = int(input["cached_tokens"]) }
        return u
    }
}

/// One Realtime reply in a conversation, as billed. Kept with the
/// conversation so the cost can always be recomputed (e.g. after a price
/// correction). Only the Realtime model is counted: transcription and the
/// text model (corrections, titles) are left out.
struct UsageRecord: Codable, Equatable {
    var model: String
    var tokens: TokenUsage?
    var at = Date()
}

/// OpenAI list prices for the Realtime models, in US dollars per million tokens, from
/// https://developers.openai.com/api/docs/pricing (checked 2026-10-13).
/// A model missing here has no known price: its calls are recorded but the
/// cost is shown as incomplete rather than guessed.
enum Pricing {
    struct TokenPrices {
        var textInput: Double, cachedTextInput: Double, textOutput: Double
        var audioInput = 0.0, cachedAudioInput = 0.0, audioOutput = 0.0
    }

    static let tokens: [String: TokenPrices] = [
        "gpt-realtime-2.1": TokenPrices(textInput: 4, cachedTextInput: 0.4, textOutput: 24,
                                        audioInput: 32, cachedAudioInput: 0.4, audioOutput: 64),
    ]

    /// The call's cost in dollars, or nil when its model has no known price.
    static func cost(_ r: UsageRecord) -> Double? {
        guard let p = tokens[r.model], let t = r.tokens else { return nil }
        // Cached tokens are counted inside the input totals; bill them at the cached rate.
        let text = Double(t.textInput - t.cachedTextInput) * p.textInput + Double(t.cachedTextInput) * p.cachedTextInput
            + Double(t.textOutput) * p.textOutput
        let audio = Double(t.audioInput - t.cachedAudioInput) * p.audioInput
            + Double(t.cachedAudioInput) * p.cachedAudioInput + Double(t.audioOutput) * p.audioOutput
        return (text + audio) / 1_000_000
    }

    /// A conversation's total, and whether some calls had no known price.
    static func total(_ records: [UsageRecord]) -> (dollars: Double, incomplete: Bool) {
        var sum = 0.0, incomplete = false
        for r in records {
            if let c = cost(r) { sum += c } else { incomplete = true }
        }
        return (sum, incomplete)
    }

    /// "$0.42", "$0.004", "<$0.001"; a trailing "+" when part of it is unknown.
    static func format(_ dollars: Double, incomplete: Bool = false) -> String {
        let plus = incomplete ? "+" : ""
        if dollars == 0 { return "$0" + plus }
        if dollars < 0.001 { return "<$0.001" + plus }
        if dollars < 0.1 { return String(format: "$%.3f", dollars) + plus }
        return String(format: "$%.2f", dollars) + plus
    }

    /// "in 12,345 (10,240 cached) · out 512".
    static func describe(_ t: TokenUsage) -> String {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        func f(_ v: Int) -> String { n.string(from: NSNumber(value: v)) ?? "\(v)" }
        return "in \(f(t.input)) (\(f(t.cachedInput)) cached) · out \(f(t.output))"
    }
}
