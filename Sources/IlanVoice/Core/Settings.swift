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
/// key lives in a private file (see `SecretStore`).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let reasoningEfforts = ["default", "minimal", "low", "medium", "high"]

    private let defaults = UserDefaults.standard

    @Published var apiKey: String { didSet { SecretStore.set(SecretStore.openAI, apiKey) } }
    /// Built-in web_search tool. On by default; it only reaches the model
    /// once a search API key is set.
    @Published var webSearchEnabled: Bool { didSet { defaults.set(webSearchEnabled, forKey: "webSearchEnabled") } }
    @Published var webSearchProvider: WebSearchProvider { didSet { defaults.set(webSearchProvider.rawValue, forKey: "webSearchProvider") } }
    @Published var geminiAPIKey: String { didSet { SecretStore.set(SecretStore.gemini, geminiAPIKey) } }
    @Published var geminiModel: String { didSet { defaults.set(geminiModel, forKey: "geminiModel") } }

    var webSearchAvailable: Bool {
        webSearchEnabled && !geminiAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var voiceGender: VoiceGender { didSet { defaults.set(voiceGender.rawValue, forKey: "voiceGender") } }
    /// How fast Ilan speaks, as a multiple of normal (OpenAI allows 0.25–1.5; the slider offers 0.5–1.5).
    @Published var voiceSpeed: Double {
        didSet {
            let clamped = Self.clampSpeed(voiceSpeed)
            if clamped != voiceSpeed { voiceSpeed = clamped; return }
            defaults.set(voiceSpeed, forKey: "voiceSpeed")
        }
    }
    static let speedRange = 0.5...1.5
    /// Rounded to two decimals as well as clamped: the slider steps by 0.1, and
    /// adding 0.1 repeatedly in binary floating point lands on values like
    /// 0.8999999999999999, which go onto the wire with all their digits and are
    /// rejected by the Realtime API ("invalid session.audio.output.speed: max
    /// decimal places exceeded").
    static func clampSpeed(_ value: Double) -> Double {
        let clamped = min(max(value, speedRange.lowerBound), speedRange.upperBound)
        return (clamped * 100).rounded() / 100
    }

    /// The speed as it has to go into a `session` payload. Rounding the `Double`
    /// is not enough on its own: `JSONSerialization` writes a `Double` with 17
    /// significant digits, so even an exactly rounded 0.9 is sent as
    /// 0.90000000000000002 and the API rejects it. An `NSDecimalNumber` of the
    /// rounded value is written as plain `0.9`.
    static func speedJSON(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(value: clampSpeed(value))
    }

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
    /// File tools: read_file is always on; edit_file and write_file share
    /// this one opt-in switch.
    @Published var fileChangesEnabled: Bool { didSet { defaults.set(fileChangesEnabled, forKey: "fileChangesEnabled") } }
    /// Files and folders edit_file / write_file must never touch, one per line.
    /// Everywhere else is allowed.
    @Published var fileBlockList: String { didSet { defaults.set(fileBlockList, forKey: "fileBlockList") } }
    /// Seconds before a shell command is stopped; typed in, so kept to 5…3600.
    @Published var shellTimeout: Int {
        didSet {
            let clamped = min(max(shellTimeout, 5), 3600)
            if clamped != shellTimeout { shellTimeout = clamped; return }
            defaults.set(shellTimeout, forKey: "shellTimeout")
        }
    }
    /// Runs every shell command without checking the allow-list. Off by default.
    @Published var shellBypassPermissions: Bool { didSet { defaults.set(shellBypassPermissions, forKey: "shellBypassPermissions") } }
    /// One command prefix per line; only these commands may run.
    @Published var shellAllowList: String { didSet { defaults.set(shellAllowList, forKey: "shellAllowList") } }

    var shellAllowListEntries: [String] {
        shellAllowList.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    @Published var reasoningEffort: String { didSet { defaults.set(reasoningEffort, forKey: "reasoningEffort") } }
    @Published var outputMode: OutputMode { didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") } }
    /// Drop the Dock icon while the main window is closed.
    @Published var hideDockWhenClosed: Bool { didSet { defaults.set(hideDockWhenClosed, forKey: "hideDockWhenClosed") } }
    @Published var talkTrigger: TalkTrigger { didSet { defaults.set(try? JSONEncoder().encode(talkTrigger), forKey: "talkTrigger") } }

    private init() {
        apiKey = SecretStore.get(SecretStore.openAI) ?? ""
        model = defaults.string(forKey: "model") ?? "gpt-realtime-2.1"
        voiceGender = VoiceGender(rawValue: defaults.string(forKey: "voiceGender") ?? "") ?? .female
        voiceSpeed = Self.clampSpeed(defaults.object(forKey: "voiceSpeed") as? Double ?? 1.0)
        microphone = defaults.string(forKey: "microphone") ?? MicrophoneChoice.builtIn
        transcriptionModel = defaults.string(forKey: "transcriptionModel") ?? "gpt-transcribe"
        titleModel = defaults.string(forKey: "titleModel") ?? "gpt-6-luna"
        shellEnabled = defaults.bool(forKey: "shellEnabled")
        webSearchEnabled = defaults.object(forKey: "webSearchEnabled") as? Bool ?? true
        webSearchProvider = WebSearchProvider(rawValue: defaults.string(forKey: "webSearchProvider") ?? "") ?? .gemini
        geminiAPIKey = SecretStore.get(SecretStore.gemini) ?? ""
        geminiModel = defaults.string(forKey: "geminiModel") ?? WebSearchTool.defaultGeminiModel
        shellDirectory = defaults.string(forKey: "shellDirectory") ?? "~"
        // Carried over from the two earlier switches: on if either was on.
        fileChangesEnabled = defaults.object(forKey: "fileChangesEnabled") as? Bool
            ?? (defaults.bool(forKey: "fileEditEnabled") || defaults.bool(forKey: "fileWriteEnabled"))
        fileBlockList = defaults.string(forKey: "fileBlockList") ?? FileTools.defaultBlockList
        shellTimeout = defaults.object(forKey: "shellTimeout") as? Int ?? 60
        shellBypassPermissions = defaults.bool(forKey: "shellBypassPermissions")
        shellAllowList = defaults.string(forKey: "shellAllowList") ?? ShellTool.defaultAllowList
        reasoningEffort = defaults.string(forKey: "reasoningEffort") ?? "default"
        outputMode = OutputMode(rawValue: defaults.string(forKey: "outputMode") ?? "") ?? .realtime
        hideDockWhenClosed = defaults.object(forKey: "hideDockWhenClosed") as? Bool ?? true
        talkTrigger = defaults.data(forKey: "talkTrigger").flatMap { try? JSONDecoder().decode(TalkTrigger.self, from: $0) }
            ?? TalkTrigger.migrating(defaults.string(forKey: "pushToTalkKey"))
    }

    /// Fields that only take effect on a fresh Realtime session.
    var sessionFingerprint: String {
        [apiKey, model, voice, transcriptionModel, reasoningEffort, String(shellEnabled), String(shellBypassPermissions), String(webSearchAvailable), String(fileChangesEnabled)].joined(separator: "|")
    }
}

