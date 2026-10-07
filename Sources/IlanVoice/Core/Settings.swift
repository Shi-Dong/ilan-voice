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

/// What is held down to talk: a modifier key (these never type anything into
/// the frontmost app) or an extra mouse button (the click is swallowed, so a
/// side button does not also go "Back" in your browser).
enum PushToTalkKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, function
    case middleMouse, mouseBack, mouseForward

    var id: String { rawValue }

    /// The CGEvent / NSEvent button number, for mouse buttons.
    var mouseButton: Int? {
        switch self {
        case .middleMouse: 2
        case .mouseBack: 3
        case .mouseForward: 4
        default: nil
        }
    }

    var keyCode: UInt16? {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .function: 63
        default: nil
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        case .function: .function
        default: []
        }
    }

    var label: String {
        switch self {
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .rightControl: "Right ⌃ Control"
        case .function: "fn / 🌐"
        case .middleMouse: "Middle mouse button (wheel click)"
        case .mouseBack: "Mouse side button: Back (button 4)"
        case .mouseForward: "Mouse side button: Forward (button 5)"
        }
    }

    var shortLabel: String {
        switch self {
        case .rightOption: "right ⌥"
        case .rightCommand: "right ⌘"
        case .rightControl: "right ⌃"
        case .function: "fn"
        case .middleMouse: "the middle mouse button"
        case .mouseBack: "the mouse Back button"
        case .mouseForward: "the mouse Forward button"
        }
    }
}

/// User preferences. Everything but the API key lives in UserDefaults; the
/// key lives in the login Keychain.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    static let reasoningEfforts = ["default", "minimal", "low", "medium", "high"]

    private let defaults = UserDefaults.standard

    @Published var apiKey: String { didSet { Keychain.save(apiKey) } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var voice: String { didSet { defaults.set(voice, forKey: "voice") } }
    @Published var transcriptionModel: String { didSet { defaults.set(transcriptionModel, forKey: "transcriptionModel") } }
    @Published var reasoningEffort: String { didSet { defaults.set(reasoningEffort, forKey: "reasoningEffort") } }
    @Published var outputMode: OutputMode { didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var pushToTalkKey: PushToTalkKey { didSet { defaults.set(pushToTalkKey.rawValue, forKey: "pushToTalkKey") } }

    private init() {
        apiKey = Keychain.load() ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        model = defaults.string(forKey: "model") ?? "gpt-realtime-2.1"
        voice = defaults.string(forKey: "voice") ?? "marin"
        transcriptionModel = defaults.string(forKey: "transcriptionModel") ?? "gpt-transcribe"
        reasoningEffort = defaults.string(forKey: "reasoningEffort") ?? "default"
        outputMode = OutputMode(rawValue: defaults.string(forKey: "outputMode") ?? "") ?? .realtime
        pushToTalkKey = PushToTalkKey(rawValue: defaults.string(forKey: "pushToTalkKey") ?? "") ?? .rightOption
    }

    /// Fields that only take effect on a fresh Realtime session.
    var sessionFingerprint: String {
        [apiKey, model, voice, transcriptionModel, reasoningEffort].joined(separator: "|")
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
