import AppKit
import AVFoundation
import Combine
import Foundation

/// The conversation engine: it records while the talk key is held, sends the
/// finished voice message to GPT-Realtime, runs any MCP tool calls, and plays
/// or caches the spoken reply. Every step is written to the transcript.
@MainActor
final class VoiceSession: ObservableObject {
    enum Phase: Equatable {
        case offline, connecting, ready, recording, thinking, working, speaking

        var label: String {
            switch self {
            case .offline: "Offline"
            case .connecting: "Connecting"
            case .ready: "Ready"
            case .recording: "Listening"
            case .thinking: "Thinking"
            case .working: "Using tools"
            case .speaking: "Speaking"
            }
        }
    }

    @Published private(set) var phase: Phase = .offline
    @Published private(set) var inputLevel: Float = 0
    @Published var errorMessage: String?

    let store: ConversationStore
    let mcp: MCPManager
    let clips = ClipPlayer()
    private let settings = AppSettings.shared
    private let mic = MicrophoneCapture()
    private let speaker = StreamPlayer()
    private var client: RealtimeClient?

    private var conversationID: UUID?
    private var sessionReady = false
    private var connectedFingerprint = ""
    private var bufferedAudio: [Data] = []
    private var recording = Data()
    private var recordStart = Date()
    private var commitWhenReady = false
    private var responseActive = false
    private var replyAudio: [String: Data] = [:]
    private var pendingUserAudio: Data?

    static let missingKeyMessage = "Add your OpenAI API key in Settings (⌘,)."
    private var keyWatcher: AnyCancellable?

    init(store: ConversationStore, mcp: MCPManager) {
        self.store = store
        self.mcp = mcp
        // Once a key is entered, drop the "add your key" warning and dial in.
        // Debounced so typing or pasting the key doesn't connect per keystroke.
        keyWatcher = settings.$apiKey
            .dropFirst()
            .debounce(for: .seconds(0.8), scheduler: DispatchQueue.main)
            .sink { [weak self] key in
                guard let self else { return }
                if key.isEmpty { return }
                if self.errorMessage == Self.missingKeyMessage { self.errorMessage = nil }
                if self.client == nil { self.connect() }
            }
        mic.onChunk = { [weak self] data, level in
            DispatchQueue.main.async { self?.handleMic(data, level) }
        }
        speaker.onDrained = { [weak self] in
            guard let self, self.phase == .speaking, !self.responseActive else { return }
            self.phase = .ready
        }
    }

    // MARK: Connection

    func connect() {
        guard let conv = store.selected else { return }
        guard !settings.apiKey.isEmpty else {
            errorMessage = Self.missingKeyMessage
            return
        }
        disconnect()
        conversationID = conv.id
        phase = .connecting
        let client = RealtimeClient()
        client.onEvent = { [weak self] in self?.handle($0) }
        client.onClose = { [weak self, weak client] reason in
            guard let self, self.client === client else { return }
            self.client = nil
            self.sessionReady = false
            if self.phase != .recording { self.phase = .offline }
            if let reason, reason != "Connection closed" { self.errorMessage = reason }
        }
        self.client = client
        connectedFingerprint = settings.sessionFingerprint
        client.connect(apiKey: settings.apiKey, model: settings.model)
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        sessionReady = false
        responseActive = false
        speaker.stop()
        phase = .offline
    }

    /// Re-dial if the conversation or a session-level setting changed.
    func ensureSession() {
        let stale = connectedFingerprint != settings.sessionFingerprint || conversationID != store.selectedID
        if client == nil || stale { connect() }
    }

    private func sessionConfig() -> [String: Any] {
        var instructions = Paths.loadAgent()
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short)
        instructions += "\n\n---\nCurrent local time: \(now).\n"
        if let accent = settings.accent.instruction { instructions += accent + "\n" }
        if let conv = store.conversations.first(where: { $0.id == conversationID }) {
            let history = conv.messages.filter { $0.role != .tool && !$0.text.isEmpty }.suffix(40)
            if !history.isEmpty {
                instructions += "\nThis conversation is being resumed. Earlier turns, for context:\n"
                for m in history { instructions += "\(m.role == .user ? "User" : "You"): \(m.text)\n" }
            }
        }
        var session: [String: Any] = [
            "type": "realtime",
            "model": settings.model,
            "output_modalities": ["audio"],
            "instructions": instructions,
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "turn_detection": NSNull(),
                    "transcription": ["model": settings.transcriptionModel],
                ],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "voice": settings.voice,
                ],
            ],
            "tools": mcp.realtimeTools + (settings.shellEnabled ? [ShellTool.definition] : []),
            "tool_choice": "auto",
        ]
        if settings.reasoningEffort != "default" {
            session["reasoning"] = ["effort": settings.reasoningEffort]
        }
        return ["type": "session.update", "session": session]
    }

    // MARK: Push to talk

    func pressToTalk() {
        guard phase != .recording else { return }
        errorMessage = nil
        Task {
            guard await MicrophoneCapture.requestPermission() else {
                errorMessage = "Ilan Voice needs microphone access (System Settings → Privacy & Security → Microphone)."
                return
            }
            beginRecording()
        }
    }

    private func beginRecording() {
        // Talking over a reply cuts it off, like a walkie-talkie.
        speaker.stop()
        clips.stop()
        if responseActive { client?.send(["type": "response.cancel"]) }
        ensureSession()
        if sessionReady { client?.send(["type": "input_audio_buffer.clear"]) }
        bufferedAudio.removeAll()
        recording = Data()
        recordStart = Date()
        commitWhenReady = false
        do {
            try mic.start()
            phase = .recording
            NSSound(named: "Tink")?.play()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func releaseToTalk() {
        guard phase == .recording else { return }
        mic.stop()
        inputLevel = 0
        // Ignore accidental taps: the API rejects buffers under ~100 ms anyway.
        guard PCM.seconds(recording) >= 0.3 else {
            if sessionReady { client?.send(["type": "input_audio_buffer.clear"]) }
            phase = sessionReady ? .ready : (client == nil ? .offline : .connecting)
            return
        }
        NSSound(named: "Pop")?.play()
        pendingUserAudio = recording
        phase = .thinking
        if sessionReady { commit() } else { commitWhenReady = true }
    }

    private func handleMic(_ data: Data, _ level: Float) {
        guard phase == .recording else { return }
        inputLevel = inputLevel * 0.6 + level * 0.4
        recording.append(data)
        if sessionReady {
            sendAudio(data)
        } else {
            bufferedAudio.append(data)
        }
    }

    private func sendAudio(_ data: Data) {
        client?.send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
    }

    private func commit() {
        client?.send(["type": "input_audio_buffer.commit"])
        client?.send(["type": "response.create"])
    }

    // MARK: Server events

    private func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String, let convID = conversationID else { return }
        switch type {
        case "session.created":
            client?.send(sessionConfig())

        case "session.updated":
            guard !sessionReady else { return }
            sessionReady = true
            bufferedAudio.forEach(sendAudio)
            bufferedAudio.removeAll()
            if commitWhenReady {
                commitWhenReady = false
                commit()
            } else if phase == .connecting {
                phase = .ready
            }

        case "input_audio_buffer.committed":
            guard let itemID = event["item_id"] as? String else { return }
            var msg = Message(id: itemID, role: .user, text: "", pending: true)
            if let pcm = pendingUserAudio {
                let file = "\(itemID).wav"
                try? PCM.wav(pcm).write(to: store.audioURL(convID, file))
                msg.audioFile = file
                msg.audioSeconds = PCM.seconds(pcm)
                pendingUserAudio = nil
            }
            store.update(convID) { $0.messages.append(msg) }

        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = event["item_id"] as? String, let delta = event["delta"] as? String else { return }
            store.updateMessage(convID, itemID) { $0.text += delta }

        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = event["item_id"] as? String else { return }
            let text = (event["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            store.updateMessage(convID, itemID) {
                $0.text = text.isEmpty ? "(no speech detected)" : text
                $0.pending = false
            }

        case "conversation.item.input_audio_transcription.failed":
            guard let itemID = event["item_id"] as? String else { return }
            store.updateMessage(convID, itemID) { $0.text = "(transcription failed)"; $0.pending = false }

        case "response.created":
            responseActive = true

        case "response.output_item.added":
            guard let item = event["item"] as? [String: Any], let itemID = item["id"] as? String,
                  item["type"] as? String == "message" else { return }
            let cached = settings.outputMode == .cached
            store.update(convID) {
                $0.messages.append(Message(id: itemID, role: .assistant, text: "", pending: true, listened: !cached))
            }

        case "response.output_audio_transcript.delta", "response.output_text.delta":
            guard let itemID = event["item_id"] as? String, let delta = event["delta"] as? String else { return }
            store.updateMessage(convID, itemID) { $0.text += delta }

        case "response.output_audio.delta":
            guard let itemID = event["item_id"] as? String, let b64 = event["delta"] as? String,
                  let pcm = Data(base64Encoded: b64) else { return }
            replyAudio[itemID, default: Data()].append(pcm)
            if settings.outputMode == .realtime {
                speaker.enqueue(pcm)
                phase = .speaking
            }

        case "response.output_audio.done":
            guard let itemID = event["item_id"] as? String else { return }
            saveReplyAudio(convID, itemID)

        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any], let itemID = item["id"] as? String,
                  item["type"] as? String == "message" else { return }
            saveReplyAudio(convID, itemID)
            store.updateMessage(convID, itemID) { $0.pending = false }
            retitle(convID)

        case "response.done":
            responseActive = false
            let response = event["response"] as? [String: Any] ?? [:]
            let calls = (response["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "function_call" }
            if !calls.isEmpty {
                runTools(calls, convID)
            } else if !speaker.isPlaying {
                phase = .ready
            }
            if response["status"] as? String == "failed",
               let details = response["status_details"] as? [String: Any],
               let error = details["error"] as? [String: Any] {
                errorMessage = error["message"] as? String
            }

        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Unknown error"
            // Cancelling when nothing is running is harmless.
            if (error?["code"] as? String) == "response_cancel_not_active" { return }
            errorMessage = message
            if phase == .thinking || phase == .connecting { phase = sessionReady ? .ready : .offline }

        default:
            break
        }
    }

    /// After each finished, transcribed reply, ask the title model for a fresh
    /// name. Only the newest request per conversation may apply its result.
    private var titleRequests: [UUID: Int] = [:]

    private func retitle(_ convID: UUID) {
        guard let conv = store.conversations.first(where: { $0.id == convID }), conv.titleLocked != true else { return }
        let ticket = (titleRequests[convID] ?? 0) + 1
        titleRequests[convID] = ticket
        let messages = conv.messages
        let key = settings.apiKey
        let model = settings.titleModel
        Task {
            guard let title = await ConversationTitler.title(for: messages, apiKey: key, model: model),
                  titleRequests[convID] == ticket else { return }
            store.setAutoTitle(convID, title)
        }
    }

    private func saveReplyAudio(_ convID: UUID, _ itemID: String) {
        guard let pcm = replyAudio.removeValue(forKey: itemID), !pcm.isEmpty else { return }
        let file = "\(itemID).wav"
        try? PCM.wav(pcm).write(to: store.audioURL(convID, file))
        store.updateMessage(convID, itemID) {
            $0.audioFile = file
            $0.audioSeconds = PCM.seconds(pcm)
        }
        if settings.outputMode == .cached { NSSound(named: "Glass")?.play() }
    }

    private func runTools(_ calls: [[String: Any]], _ convID: UUID) {
        phase = .working
        Task {
            await withTaskGroup(of: Void.self) { group in
                for call in calls {
                    let name = call["name"] as? String ?? ""
                    let args = call["arguments"] as? String ?? "{}"
                    let callID = call["call_id"] as? String ?? UUID().uuidString
                    store.update(convID) {
                        $0.messages.append(Message(id: callID, role: .tool, text: "", pending: true,
                                                   toolName: name, toolArguments: args))
                    }
                    group.addTask { @MainActor in
                        let output = name == ShellTool.functionName
                            ? await self.runShell(arguments: args)
                            : await self.mcp.call(functionName: name, arguments: args)
                        self.store.updateMessage(convID, callID) { $0.text = output; $0.pending = false }
                        guard self.conversationID == convID else { return }
                        self.client?.send(["type": "conversation.item.create",
                                           "item": ["type": "function_call_output", "call_id": callID, "output": output]])
                    }
                }
            }
            guard conversationID == convID, phase == .working else { return }
            phase = .thinking
            client?.send(["type": "response.create"])
        }
    }

    /// Handles a run_shell call: checks it is enabled and that every part of
    /// the command is allow-listed, then runs it. Never prompts the user.
    private func runShell(arguments: String) async -> String {
        guard settings.shellEnabled else { return "Error: the shell tool is turned off in Settings." }
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        guard let command = (args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return "Error: no command given." }
        let directory = (args["working_directory"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? settings.shellDirectory
        if let reason = ShellTool.refusal(for: command, allowList: settings.shellAllowListEntries) {
            return "Not run: \(reason). Only allow-listed read-only commands can run; the user can add commands under Settings → General → Shell commands."
        }
        return await ShellTool.run(command, in: directory, timeout: TimeInterval(max(5, settings.shellTimeout)))
    }

    // MARK: Playback of saved clips

    func play(_ message: Message) {
        guard let convID = store.selectedID, let file = message.audioFile else { return }
        speaker.stop()
        store.updateMessage(convID, message.id) { $0.listened = true }
        clips.toggle(id: message.id, url: store.audioURL(convID, file))
    }

    /// Plays the oldest reply the user has not heard yet, then the next one.
    func playNextUnheard() {
        guard let conv = store.selected,
              let next = conv.messages.first(where: { $0.role == .assistant && !$0.listened && $0.audioFile != nil }) else { return }
        let convID = conv.id
        store.updateMessage(convID, next.id) { $0.listened = true }
        clips.toggle(id: next.id, url: store.audioURL(convID, next.audioFile!)) { [weak self] in
            self?.playNextUnheard()
        }
    }
}
