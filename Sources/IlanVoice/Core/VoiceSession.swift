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
    private let mic: VoiceInput
    private let speaker: VoiceOutput
    /// The conversation this session talks in: the one selected on the Mac,
    /// or the iPhone's own conversation (see PhoneServer).
    private let target: () -> UUID?
    /// True for the session that serves the iPhone web app: always real-time,
    /// and no Mac sounds or Mac replay bookkeeping.
    let isRemote: Bool
    /// Messages this session has seen. One it hasn't seen means the other
    /// session (Mac or iPhone) spoke in this conversation, so the next turn
    /// starts a fresh session that includes it.
    private var knownMessageIDs: Set<String> = []
    private var client: RealtimeClient?

    private var conversationID: UUID?
    private var sessionReady = false
    private var connectedFingerprint = ""
    private var bufferedAudio: [Data] = []
    private var recording = Data()
    private var recordStart = Date()
    private var commitWhenReady = false
    private var responseActive = false
    private var talkKeyHeld = false
    /// The current press cut Ilan off (so a quick tap reads as "stop").
    private var interruptedThisPress = false

    /// What a press of the talk key turned out to be, for the floating pill.
    enum PressOutcome { case sent, stoppedSpeech, discarded }
    /// Shorter recordings are taps, never sent; the floating pill also waits
    /// this long before it shows "Listening".
    static let minRecordingSeconds = 0.2
    let pressEnded = PassthroughSubject<PressOutcome, Never>()
    private var finishingRecording = false
    private var currentResponseID: String?
    /// Audio for this response is dropped: the user interrupted it.
    private var mutedResponseID: String?
    /// Bumped on every interrupt so a tool loop knows not to ask for a reply.
    private var interruptGeneration = 0
    private var speakingItemID: String?
    private var speakingItemStartFrame: Int?
    private var replyAudio: [String: Data] = [:]
    private var pendingUserAudio: Data?

    static let missingKeyMessage = "Add your OpenAI API key in Settings (⌘,)."
    private var keyWatcher: AnyCancellable?
    private var speedWatcher: AnyCancellable?

    init(store: ConversationStore, mcp: MCPManager,
         input: VoiceInput = MacMicrophone(), output: VoiceOutput = StreamPlayer(),
         isRemote: Bool = false, target: (() -> UUID?)? = nil) {
        self.store = store
        self.mcp = mcp
        self.mic = input
        self.speaker = output
        self.isRemote = isRemote
        self.target = target ?? { [weak store] in store?.selectedID }
        // Once a key is entered, drop the "add your key" warning and dial in.
        // Debounced so typing or pasting the key doesn't connect per keystroke.
        // A new speed applies from the next reply, without reconnecting.
        // Rounded here too: @Published publishes from willSet, so this sees the
        // slider's raw value before voiceSpeed's didSet has rounded it.
        speedWatcher = settings.$voiceSpeed
            .dropFirst()
            .map(AppSettings.clampSpeed)
            .removeDuplicates()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] speed in
                guard let self, self.sessionReady else { return }
                self.client?.send(["type": "session.update",
                                   "session": ["type": "realtime", "audio": ["output": ["speed": AppSettings.speedJSON(speed)]]]])
            }
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
        guard let id = target(), let conv = store.conversations.first(where: { $0.id == id }) else { return }
        guard !settings.apiKey.isEmpty else {
            errorMessage = Self.missingKeyMessage
            return
        }
        disconnect()
        conversationID = conv.id
        knownMessageIDs = Set(conv.messages.map(\.id))
        phase = .connecting
        let client = RealtimeClient()
        client.onEvent = { [weak self] in self?.handle($0) }
        client.onClose = { [weak self, weak client] reason in
            guard let self, self.client === client else { return }
            self.client = nil
            self.sessionReady = false
            self.cancelWatchdog()
            if self.retryUnsentTurn() { return }
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
        let stale = connectedFingerprint != settings.sessionFingerprint || conversationID != target()
            || someoneElseSpoke
        if client == nil || stale { connect() }
    }

    private var someoneElseSpoke: Bool {
        guard let id = conversationID, let conv = store.conversations.first(where: { $0.id == id }) else { return false }
        return conv.messages.contains { !knownMessageIDs.contains($0.id) }
    }

    /// Records the messages this session wrote, after each of its own changes.
    private func noteOwnMessages() {
        guard let id = conversationID, let conv = store.conversations.first(where: { $0.id == id }) else { return }
        knownMessageIDs.formUnion(conv.messages.map(\.id))
    }

    /// Grounds speech recognition with the user's dictionary: a prompt for
    /// every model, plus `keywords` for the models that take them. Both
    /// gpt-transcribe and gpt-live-transcribe accept keyword hints; older ones
    /// (gpt-4o-transcribe, whisper-1) would reject the field.
    private func transcriptionConfig(_ dictionary: [String]) -> [String: Any] {
        var config: [String: Any] = ["model": settings.transcriptionModel]
        if let prompt = UserDictionary.transcriptionPrompt(dictionary) { config["prompt"] = prompt }
        if Self.acceptsKeywords(settings.transcriptionModel), !dictionary.isEmpty {
            config["keywords"] = Array(dictionary.prefix(100))
        }
        return config
    }

    static func acceptsKeywords(_ model: String) -> Bool {
        model.hasPrefix("gpt-transcribe") || model.contains("live-transcribe")
    }

    private func sessionConfig() -> [String: Any] {
        var instructions = Paths.loadAgent()
        let now = DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short)
        instructions += "\n\n---\nCurrent local time: \(now).\n"
        let dictionary = UserDictionary.terms()
        if let vocabulary = UserDictionary.instructions(dictionary) { instructions += vocabulary + "\n" }
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
                    "transcription": transcriptionConfig(dictionary),
                ],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "voice": settings.voice,
                    "speed": AppSettings.speedJSON(settings.voiceSpeed),
                ],
            ],
            "tools": builtInTools(),
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
        // Stop Ilan the instant the key goes down, even for a quick tap that
        // never becomes a recording. Remembered so the pill can say so.
        interruptedThisPress = interrupt()
        talkKeyHeld = true
        Task {
            guard await mic.requestPermission() else {
                errorMessage = "Ilan Voice needs microphone access (System Settings → Privacy & Security → Microphone)."
                return
            }
            // A quick tap can be over before permission comes back: then the
            // tap only interrupted Ilan, and nothing is recorded.
            guard talkKeyHeld else {
                pressEnded.send(interruptedThisPress ? .stoppedSpeech : .discarded)
                return
            }
            beginRecording()
        }
    }

    /// Silences Ilan right away: stops the speaker and any replayed clip,
    /// cancels the reply being generated, drops audio from it that is still on
    /// its way, skips the follow-up to any running tool call, and tells the
    /// server how much of the reply was actually heard.
    /// Returns true if there was something to stop.
    @discardableResult
    func interrupt() -> Bool {
        let wasSpeaking = speaker.isPlaying || responseActive || phase == .speaking || phase == .working
        let wasReplaying = clips.playingID != nil
        clips.stop()
        guard wasSpeaking else { return wasReplaying }
        if let itemID = speakingItemID, let start = speakingItemStartFrame, client != nil {
            let heardMs = max(0, (speaker.playedFrames - start) * 1000 / Int(PCM.sampleRate))
            client?.send(["type": "conversation.item.truncate", "item_id": itemID,
                          "content_index": 0, "audio_end_ms": heardMs])
        }
        speaker.stop()
        if responseActive {
            mutedResponseID = currentResponseID
            client?.send(["type": "response.cancel"])
            responseActive = false
        }
        interruptGeneration += 1
        speakingItemID = nil
        speakingItemStartFrame = nil
        if let convID = conversationID {
            for m in store.conversations.first(where: { $0.id == convID })?.messages ?? [] where m.pending && m.role == .assistant {
                store.updateMessage(convID, m.id) { $0.pending = false }
            }
        }
        if phase == .speaking || phase == .working || phase == .thinking { phase = sessionReady ? .ready : .offline }
        return true
    }

    private func beginRecording() {
        ensureSession()
        if sessionReady { client?.send(["type": "input_audio_buffer.clear"]) }
        bufferedAudio.removeAll()
        recording = Data()
        recordStart = Date()
        commitWhenReady = false
        do {
            try mic.start()
            phase = .recording
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func releaseToTalk() {
        talkKeyHeld = false
        guard phase == .recording, !finishingRecording else { return }
        mic.stop()
        // The microphone hands over audio in small batches; give the last one
        // a moment to arrive so the end of the sentence isn't cut off.
        finishingRecording = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.finishingRecording = false
            self.finishRecording()
        }
    }

    private func finishRecording() {
        guard phase == .recording else { return }
        inputLevel = 0
        // Ignore accidental taps: the API rejects buffers under ~100 ms anyway.
        // Silence (a press with nothing said) is dropped the same way, so it
        // never shows up in the conversation or reaches the model.
        guard PCM.seconds(recording) >= Self.minRecordingSeconds, PCM.containsSpeech(recording) else {
            if sessionReady { client?.send(["type": "input_audio_buffer.clear"]) }
            pressEnded.send(interruptedThisPress ? .stoppedSpeech : .discarded)
            phase = sessionReady ? .ready : (client == nil ? .offline : .connecting)
            return
        }
        pressEnded.send(.sent)
        // "Breeze" in System Settings → Sound; the file is still Blow.aiff.
        if !isRemote { NSSound(named: "Blow")?.play() }
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
        unsentTurn = pendingUserAudio ?? recording
        client?.send(["type": "input_audio_buffer.commit"])
        client?.send(["type": "response.create"])
        armWatchdog()
    }

    /// The recording got past the loudness check but the transcriber heard no
    /// words in it (a cough, a door). Cancels the reply it started and removes
    /// the turn, and anything said back to it, from the app and the server.
    private func discardSilentTurn(_ convID: UUID, _ itemID: String) {
        guard let messages = store.conversations.first(where: { $0.id == convID })?.messages,
              let index = messages.firstIndex(where: { $0.id == itemID }) else { return }
        let dropped = messages[index...].prefix { $0.id == itemID || $0.role == .assistant }
        interrupt()
        for m in dropped {
            client?.send(["type": "conversation.item.delete", "item_id": m.id])
            if let file = m.audioFile { try? FileManager.default.removeItem(at: store.audioURL(convID, file)) }
        }
        let ids = Set(dropped.map(\.id))
        store.update(convID) { $0.messages.removeAll { ids.contains($0.id) } }
    }

    // MARK: Never wait forever

    /// The message just sent, kept until the server confirms it, so a dropped
    /// connection can be redialled and the message sent again once.
    private var unsentTurn: Data?
    private var turnRetried = false
    private var watchdog: DispatchWorkItem?
    private static let replyTimeout: TimeInterval = 20

    /// If the server says nothing at all after a message, the connection is
    /// dead even if the socket hasn't noticed yet.
    private func armWatchdog() {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .thinking else { return }
            self.client?.disconnect()
            self.client = nil
            self.sessionReady = false
            if !self.retryUnsentTurn() {
                self.phase = .offline
                self.errorMessage = "No reply from OpenAI. Check your connection and try again."
            }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyTimeout, execute: work)
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// Redials and resends the unconfirmed message, once. Returns false if
    /// there was nothing to resend or it was already retried.
    private func retryUnsentTurn() -> Bool {
        guard let turn = unsentTurn, !turnRetried else {
            unsentTurn = nil
            turnRetried = false
            return false
        }
        turnRetried = true
        connect()
        pendingUserAudio = turn
        bufferedAudio = [turn]
        commitWhenReady = true
        phase = .thinking
        return true
    }

    // MARK: Server events

    private func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String, let convID = conversationID else { return }
        if type != "session.created" && type != "session.updated" { cancelWatchdog() }
        defer { noteOwnMessages() }
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
            unsentTurn = nil
            turnRetried = false
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
            guard !text.isEmpty else {
                discardSilentTurn(convID, itemID)
                return
            }
            store.updateMessage(convID, itemID) {
                $0.text = text
                $0.pending = false
            }

        case "conversation.item.input_audio_transcription.failed":
            guard let itemID = event["item_id"] as? String else { return }
            store.updateMessage(convID, itemID) { $0.text = "(transcription failed)"; $0.pending = false }

        case "response.created":
            responseActive = true
            currentResponseID = (event["response"] as? [String: Any])?["id"] as? String

        case "response.output_item.added":
            guard let item = event["item"] as? [String: Any], let itemID = item["id"] as? String,
                  item["type"] as? String == "message" else { return }
            let cached = !isRemote && settings.outputMode == .cached
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
            let muted = mutedResponseID != nil && event["response_id"] as? String == mutedResponseID
            if (isRemote || settings.outputMode == .realtime) && !muted {
                if speakingItemID != itemID {
                    speakingItemID = itemID
                    speakingItemStartFrame = speaker.enqueuedFrames
                }
                speaker.enqueue(pcm)
                phase = .speaking
            }

        case "response.output_audio.done":
            guard let itemID = event["item_id"] as? String else { return }
            speaker.flush()
            saveReplyAudio(convID, itemID)

        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any], let itemID = item["id"] as? String,
                  item["type"] as? String == "message" else { return }
            saveReplyAudio(convID, itemID)
            store.updateMessage(convID, itemID) { $0.pending = false }
            retitle(convID)

        case "response.done":
            let response = event["response"] as? [String: Any] ?? [:]
            // The reply the user cut off: no tools, no state changes.
            if let id = response["id"] as? String, id == mutedResponseID {
                mutedResponseID = nil
                return
            }
            responseActive = false
            let calls = (response["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "function_call" }
            speaker.flush()
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
        if isRemote {
            return
        } else if settings.outputMode == .cached {
            NSSound(named: "Glass")?.play()
        } else {
            clips.markPlayed(id: itemID, url: store.audioURL(convID, file))
        }
    }

    private func runTools(_ calls: [[String: Any]], _ convID: UUID) {
        phase = .working
        let generation = interruptGeneration
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
                    noteOwnMessages()
                    group.addTask { @MainActor in
                        let output: String
                        switch name {
                        case ShellTool.functionName: output = await self.runShell(arguments: args, conversation: convID)
                        case ShellTool.closeFunctionName:
                            output = ShellSessions.shared.close(convID)
                                ? "Closed the bash session." : "There was no open bash session."
                        case WebSearchTool.functionName: output = await self.runWebSearch(arguments: args)
                        case FileTools.readName, FileTools.editName, FileTools.writeName:
                            output = self.runFileTool(name, arguments: args)
                        default: output = await self.mcp.call(functionName: name, arguments: args)
                        }
                        self.store.updateMessage(convID, callID) { $0.text = output; $0.pending = false }
                        self.noteOwnMessages()
                        guard self.conversationID == convID else { return }
                        self.client?.send(["type": "conversation.item.create",
                                           "item": ["type": "function_call_output", "call_id": callID, "output": output]])
                    }
                }
            }
            guard conversationID == convID, phase == .working, interruptGeneration == generation else { return }
            phase = .thinking
            client?.send(["type": "response.create"])
        }
    }

    /// Handles a run_shell call: checks it is enabled and that every part of
    /// the command is allow-listed, then runs it. Never prompts the user.
    private func runWebSearch(arguments: String) async -> String {
        guard settings.webSearchAvailable else { return "Error: web search is turned off or has no API key." }
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else { return "Error: no query given." }
        return await WebSearchTool.search(query, provider: settings.webSearchProvider,
                                          apiKey: settings.geminiAPIKey, model: settings.geminiModel)
    }

    /// MCP tools plus the built-in ones that are turned on.
    private func builtInTools() -> [[String: Any]] {
        var tools: [[String: Any]] = mcp.realtimeTools
        if settings.shellEnabled { tools += [ShellTool.definition(bypass: settings.bypassActive), ShellTool.closeDefinition] }
        if settings.webSearchAvailable { tools.append(WebSearchTool.definition) }
        tools.append(FileTools.readDefinition)
        if settings.fileChangesAllowed { tools += [FileTools.editDefinition, FileTools.writeDefinition] }
        return tools
    }

    /// read_file always; edit_file / write_file only when changes are turned on in Settings.
    private func runFileTool(_ name: String, arguments: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        guard let path = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return "Error: no path given."
        }
        let base = settings.shellDirectory
        let blocked = settings.bypassActive ? [] : FileTools.blockedPaths(settings.fileBlockList)
        if name != FileTools.readName, !settings.fileChangesAllowed {
            return "Error: changing files is turned off in Settings."
        }
        switch name {
        case FileTools.editName:
            return FileTools.edit(path: path, oldText: args["old_text"] as? String ?? "",
                                  newText: args["new_text"] as? String ?? "",
                                  replaceAll: args["replace_all"] as? Bool ?? false, base: base, blocked: blocked)
        case FileTools.writeName:
            return FileTools.write(path: path, content: args["content"] as? String ?? "", base: base, blocked: blocked)
        default:
            return FileTools.read(path: path, offset: (args["offset"] as? NSNumber)?.intValue,
                                  limit: (args["limit"] as? NSNumber)?.intValue, base: base)
        }
    }

    private func runShell(arguments: String, conversation: UUID) async -> String {
        guard settings.shellEnabled else { return "Error: the shell tool is turned off in Settings." }
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        guard let command = (args["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return "Error: no command given." }
        if !settings.bypassActive,
           let reason = ShellTool.refusal(for: command, allowList: settings.shellAllowListEntries) {
            return "Not run: \(reason). Only allow-listed read-only commands can run; the user can add commands under Settings → Shell."
        }
        // A requested directory becomes a cd inside the session, so it sticks.
        var script = command
        if let dir = (args["working_directory"] as? String), !dir.isEmpty {
            let path = (dir as NSString).expandingTildeInPath.replacingOccurrences(of: "'", with: "'\\''")
            script = "cd -- '\(path)' && \(command)"
        }
        return await ShellSessions.shared.run(script, conversation: conversation, directory: settings.shellDirectory,
                                              timeout: TimeInterval(max(5, settings.shellTimeout)))
    }

    // MARK: Playback of saved clips

    func play(_ message: Message) {
        guard let convID = store.selectedID, let file = message.audioFile else { return }
        speaker.stop()
        store.updateMessage(convID, message.id) { $0.listened = true }
        clips.toggle(id: message.id, url: store.audioURL(convID, file))
    }

    /// Plays the oldest reply the user has not heard yet, then the next one.
    /// Plays the assistant reply heard most recently again from the start,
    /// cutting off anything Ilan is saying now.
    func replayLast() {
        guard let last = clips.lastPlayed, FileManager.default.fileExists(atPath: last.url.path) else { return }
        interrupt()
        clips.stop()
        clips.toggle(id: last.id, url: last.url)
    }

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
