import AppKit
import Foundation
import Security

/// How a finished assistant reply reaches the speaker.
enum OutputMode: String, CaseIterable, Identifiable {
    /// Audio is played the moment it streams in.
    case realtime
    /// Audio is kept on disk; the user presses play when they are ready.
    case cached

    var id: String { rawValue }
    var label: String { self == .realtime ? "Real-time" : "Cached" }
    var symbol: String { self == .realtime ? "speaker.wave.2.fill" : "tray.full.fill" }
}

enum Accent: String, CaseIterable, Identifiable {
    case american, british

    var id: String { rawValue }
    var label: String { self == .american ? "American" : "British" }

    /// Added to the instructions; nil when the voice's natural accent is right.
    var instruction: String? {
        switch self {
        case .american: nil
        case .british: "Always speak English with a natural British (Southern English, RP) accent, and use British spelling and vocabulary."
        }
    }
}

enum VoiceGender: String, CaseIterable, Identifiable {
    case female, male

    var id: String { rawValue }
    var label: String { self == .female ? "Female" : "Male" }
}

/// User preferences. Everything but the API key lives in UserDefaults; the
/// key lives in the login Keychain.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let reasoningEfforts = ["default", "minimal", "low", "medium", "high"]

    private let defaults = UserDefaults.standard

    @Published var apiKey: String { didSet { Keychain.save(apiKey) } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var accent: Accent { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    @Published var voiceGender: VoiceGender { didSet { defaults.set(voiceGender.rawValue, forKey: "voiceGender") } }

    /// The Realtime voice name. OpenAI's built-in voices are all American
    /// English, so gender picks the voice (OpenAI recommends marin and cedar
    /// for quality) and the accent is asked for in the instructions.
    var voice: String { voiceGender == .female ? "marin" : "cedar" }
    @Published var transcriptionModel: String { didSet { defaults.set(transcriptionModel, forKey: "transcriptionModel") } }
    @Published var reasoningEffort: String { didSet { defaults.set(reasoningEffort, forKey: "reasoningEffort") } }
    @Published var outputMode: OutputMode { didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var talkTrigger: TalkTrigger { didSet { defaults.set(try? JSONEncoder().encode(talkTrigger), forKey: "talkTrigger") } }

    private init() {
        apiKey = Keychain.load() ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        model = defaults.string(forKey: "model") ?? "gpt-realtime-2.1"
        accent = Accent(rawValue: defaults.string(forKey: "accent") ?? "") ?? .american
        voiceGender = VoiceGender(rawValue: defaults.string(forKey: "voiceGender") ?? "") ?? .female
        transcriptionModel = defaults.string(forKey: "transcriptionModel") ?? "gpt-transcribe"
        reasoningEffort = defaults.string(forKey: "reasoningEffort") ?? "default"
        outputMode = OutputMode(rawValue: defaults.string(forKey: "outputMode") ?? "") ?? .realtime
        talkTrigger = defaults.data(forKey: "talkTrigger").flatMap { try? JSONDecoder().decode(TalkTrigger.self, from: $0) }
            ?? TalkTrigger.migrating(defaults.string(forKey: "pushToTalkKey"))
    }

    /// Fields that only take effect on a fresh Realtime session.
    var sessionFingerprint: String {
        [apiKey, model, voice, accent.rawValue, transcriptionModel, reasoningEffort].joined(separator: "|")
    }
}

enum Keychain {
    private static let service = "Ilan Voice"
    private static let account = "openai-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
