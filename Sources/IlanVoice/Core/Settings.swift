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

enum VoiceGender: String, CaseIterable, Identifiable {
    case female, male

    var id: String { rawValue }
    var label: String { self == .female ? "Female" : "Male" }
}

/// User preferences. Everything but the API key lives in UserDefaults; the
/// key lives in a private file (see `APIKeyStore` below).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let reasoningEfforts = ["default", "minimal", "low", "medium", "high"]

    private let defaults = UserDefaults.standard

    @Published var apiKey: String { didSet { APIKeyStore.save(apiKey) } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var voiceGender: VoiceGender { didSet { defaults.set(voiceGender.rawValue, forKey: "voiceGender") } }

    /// The Realtime voice name: OpenAI recommends marin and cedar for quality.
    var voice: String { voiceGender == .female ? "marin" : "cedar" }
    /// MicrophoneChoice.builtIn, MicrophoneChoice.system, or a device UID.
    @Published var microphone: String { didSet { defaults.set(microphone, forKey: "microphone") } }
    @Published var transcriptionModel: String { didSet { defaults.set(transcriptionModel, forKey: "transcriptionModel") } }
    /// Text model that names conversations after each reply.
    @Published var titleModel: String { didSet { defaults.set(titleModel, forKey: "titleModel") } }
    /// The built-in run_shell tool. Off until the user turns it on.
    @Published var shellEnabled: Bool { didSet { defaults.set(shellEnabled, forKey: "shellEnabled") } }
    @Published var shellDirectory: String { didSet { defaults.set(shellDirectory, forKey: "shellDirectory") } }
    @Published var shellTimeout: Int { didSet { defaults.set(shellTimeout, forKey: "shellTimeout") } }
    /// One command prefix per line; only these commands may run.
    @Published var shellAllowList: String { didSet { defaults.set(shellAllowList, forKey: "shellAllowList") } }

    var shellAllowListEntries: [String] {
        shellAllowList.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    @Published var reasoningEffort: String { didSet { defaults.set(reasoningEffort, forKey: "reasoningEffort") } }
    @Published var outputMode: OutputMode { didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var talkTrigger: TalkTrigger { didSet { defaults.set(try? JSONEncoder().encode(talkTrigger), forKey: "talkTrigger") } }

    private init() {
        apiKey = APIKeyStore.load() ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        model = defaults.string(forKey: "model") ?? "gpt-realtime-2.1"
        voiceGender = VoiceGender(rawValue: defaults.string(forKey: "voiceGender") ?? "") ?? .female
        microphone = defaults.string(forKey: "microphone") ?? MicrophoneChoice.builtIn
        transcriptionModel = defaults.string(forKey: "transcriptionModel") ?? "gpt-transcribe"
        titleModel = defaults.string(forKey: "titleModel") ?? "gpt-6-luna"
        shellEnabled = defaults.bool(forKey: "shellEnabled")
        shellDirectory = defaults.string(forKey: "shellDirectory") ?? "~"
        shellTimeout = defaults.object(forKey: "shellTimeout") as? Int ?? 60
        shellAllowList = defaults.string(forKey: "shellAllowList") ?? ShellTool.defaultAllowList
        reasoningEffort = defaults.string(forKey: "reasoningEffort") ?? "default"
        outputMode = OutputMode(rawValue: defaults.string(forKey: "outputMode") ?? "") ?? .realtime
        talkTrigger = defaults.data(forKey: "talkTrigger").flatMap { try? JSONDecoder().decode(TalkTrigger.self, from: $0) }
            ?? TalkTrigger.migrating(defaults.string(forKey: "pushToTalkKey"))
    }

    /// Fields that only take effect on a fresh Realtime session.
    var sessionFingerprint: String {
        [apiKey, model, voice, transcriptionModel, reasoningEffort, String(shellEnabled)].joined(separator: "|")
    }
}

/// Stores the OpenAI API key in `~/Library/Application Support/Ilan Voice/
/// openai-api-key`, readable only by you (mode 0600), the same way `mcp.json`
/// already holds MCP tokens.
///
/// It used to live in the login Keychain. Keychain items remember which build
/// of an app created them, and Ilan Voice is rebuilt on your Mac at every
/// update without an Apple developer certificate, so macOS treated each update
/// as a stranger and asked for your password to unlock the key. Apps from the
/// App Store or signed by a registered developer don't hit this.
enum APIKeyStore {
    private static var file: URL { Paths.root.appendingPathComponent("openai-api-key") }
    private static let service = "Ilan Voice"
    private static let account = "openai-api-key"

    static func load() -> String? {
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        }
        // One-time move out of the Keychain (this may ask for the password a
        // last time); afterwards the Keychain item is deleted.
        guard let key = loadLegacy() else { return nil }
        save(key)
        deleteLegacy()
        return key
    }

    static func save(_ value: String) {
        guard !value.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        FileManager.default.createFile(atPath: file.path, contents: Data(value.utf8),
                                       attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static var legacyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func loadLegacy() -> String? {
        var q = legacyQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteLegacy() {
        SecItemDelete(legacyQuery as CFDictionary)
    }
}
