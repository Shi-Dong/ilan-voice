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

    /// Internal (not private) so the unit tests can feed server events.
    var conversationID: UUID?
    private var sessionReady = false
    private var connectedFingerprint = ""
    /// When the current Realtime session was opened. OpenAI ends every
    /// session after 60 minutes, so an old one is replaced before a new turn.
    private var sessionStartedAt = Date()
    static let sessionRefreshAge: TimeInterval = 50 * 60
    private var bufferedAudio: [Data] = []
    /// This press's audio so far. Internal (read-only) so the unit tests can check it.
    private(set) var recording = Data()
    /// When the microphone started for this press. It may have recorded
    /// quietly for a while before going live (see "Push to talk").
    private(set) var recordStart = Date()
    /// The microphone this press records from, as macOS names it (shown in the pill).
    private(set) var microphoneName: String?
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
    /// The Realtime model of the open session (what its replies are billed as).
    private var sessionModel = ""
    /// Tokens of replies that produced no message (tool-calling steps), to
    /// show with the next message Ilan says.
    private var unshownReplyUsage = TokenUsage()
    /// Interrupted after asking for a reply but before it started (e.g. right
    /// after a tool result went back): cancel that reply as soon as it starts.
    private var cancelNextResponse = false
    /// Bumped on every interrupt so a tool loop knows not to ask for a reply.
    private var interruptGeneration = 0
    /// The reply item being played, and where its audio started in the
    /// speaker's frame count. (Read by PhoneClient, to tell the phone which
    /// reply it is getting and where in it.)
    private(set) var speakingItemID: String?
    private(set) var speakingItemStartFrame: Int?
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
            self.phase = self.idlePhase
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
            self.connectionClosed(reason: reason)
        }
        self.client = client
        connectedFingerprint = sessionFingerprint
        sessionStartedAt = Date()
        sessionModel = settings.model
        client.connect(apiKey: settings.apiKey, model: settings.model)
    }

    /// The connection to OpenAI closed. Internal (not private) so the unit
    /// tests can drop it.
    func connectionClosed(reason: String?) {
        let report = Self.shouldReport(closeReason: reason, phase: phase, responseActive: responseActive)
        client = nil
        sessionReady = false
        cancelWatchdog()
        if retryUnsentTurn() { return }
        // A conversation carries on: reconnect (configured for it) after a moment.
        if conversationActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.conversationActive, self.client == nil else { return }
                self.connect()
            }
        }
        if phase != .recording { phase = .offline }
        if report, let reason {
            errorMessage = reason
            connectionError = reason
        }
    }

    /// The last connection error shown, so it can be cleared once a new
    /// session is up.
    private var connectionError: String?

    /// OpenAI's "Your session hit the maximum duration of 60 minutes" error.
    static func isSessionExpiry(code: String?, message: String) -> Bool {
        code == "session_expired" || message.localizedCaseInsensitiveContains("maximum duration")
    }

    /// Whether a dropped connection is worth a warning. OpenAI and the network
    /// close idle sessions all the time ("Socket is not connected", "The
    /// socket is closed"); the next press simply reconnects, so a warning then
    /// is a false alarm. It is only shown when a reply was on its way and the
    /// one automatic retry could not save it.
    static func shouldReport(closeReason reason: String?, phase: Phase, responseActive: Bool) -> Bool {
        guard let reason, !reason.isEmpty, reason != "Connection closed" else { return false }
        return responseActive || phase == .thinking || phase == .working || phase == .speaking
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        sessionReady = false
        responseActive = false
        cancelNextResponse = false
        unshownReplyUsage = TokenUsage()
        speaker.stop()
        phase = .offline
    }

    /// Re-dial if the conversation or a session-level setting changed.
    func ensureSession() {
        let stale = connectedFingerprint != sessionFingerprint || conversationID != target()
            || Date().timeIntervalSince(sessionStartedAt) > Self.sessionRefreshAge
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
    private func transcriptionConfig(_ dictionary: [String], context: String? = nil) -> [String: Any] {
        var config: [String: Any] = ["model": settings.transcriptionModel]
        if let prompt = UserDictionary.transcriptionPrompt(dictionary, context: context) { config["prompt"] = prompt }
        if Self.acceptsKeywords(settings.transcriptionModel), !dictionary.isEmpty {
            config["keywords"] = Array(dictionary.prefix(100))
        }
        return config
    }

    /// What Ilan said last in this conversation, as text.
    private func lastAssistantText() -> String? {
        guard let id = conversationID, let conv = store.conversations.first(where: { $0.id == id }) else { return nil }
        return conv.messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text
    }

    /// Before each turn, hands the transcriber Ilan's latest reply as context
    /// (the session itself only had it from when it started).
    private func refreshTranscriptionContext() {
        guard let context = lastAssistantText() else { return }
        client?.send(["type": "session.update", "session": [
            "type": "realtime",
            "audio": ["input": ["transcription": transcriptionConfig(UserDictionary.terms(), context: context)]],
        ]])
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
                    "turn_detection": turnDetection,
                    "noise_reduction": noiseReduction,
                    "transcription": transcriptionConfig(dictionary, context: lastAssistantText()),
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

    // MARK: Typed messages

    /// A typed message waiting for the session to become ready.
    private var pendingTextItem: [String: Any]?

    /// Sends a typed message; Ilan answers out loud like a spoken one.
    /// Returns false (and sends nothing) while the user is recording or
    /// holding the talk key.
    @discardableResult
    func sendText(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase != .recording, !talkKeyHeld, let convID = target() else { return false }
        guard !targetLiveOnPhone else { errorMessage = Self.liveOnPhoneMessage; return false }
        errorMessage = nil
        interrupt()
        ensureSession()
        guard conversationID == convID else { return false }
        let itemID = Self.newItemID()
        store.update(convID) {
            Self.settleEarlierCorrections(&$0)
            $0.messages.append(Message(id: itemID, role: .user, text: text, typed: true))
        }
        noteOwnMessages()
        let item: [String: Any] = [
            "type": "conversation.item.create",
            "item": ["id": itemID, "type": "message", "role": "user",
                     "content": [["type": "input_text", "text": text]]],
        ]
        phase = .thinking
        if sessionReady {
            sendTextItem(item)
        } else {
            pendingTextItem = item
        }
        return true
    }

    private func sendTextItem(_ item: [String: Any]) {
        client?.send(item)
        client?.send(["type": "response.create"])
        armWatchdog()
    }

    /// Realtime item ids may be chosen by the client (at most 32 characters).
    static func newItemID() -> String {
        "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
    }

    // MARK: Conversation mode (the iPhone app)

    /// Hands-free: the microphone streams the whole time and OpenAI decides
    /// from what was said when each turn is over (semantic turn detection),
    /// then answers by itself. Speaking over Ilan stops its reply.
    private(set) var conversationActive = false

    /// OpenAI decides when a turn starts and ends; the app decides whether it
    /// was speech (see `minTurnVoicedFrames`), then interrupts and asks for the
    /// reply itself. So noise never cuts Ilan off or gets an answer.
    static let semanticTurns: [String: Any] = [
        "type": "semantic_vad", "eagerness": "auto", "create_response": false, "interrupt_response": false,
    ]
    /// A turn counts as speech after this many voiced 20 ms frames (0.2 s).
    /// Measured on real iPhone turns: speech, even quiet, had 42 or more;
    /// noise turns had 1 and 6; a quick "Yeah." had 7 (ignored too: a
    /// backchannel shouldn't cut Ilan off).
    static let minTurnVoicedFrames = 10
    /// While Ilan is talking on the phone, the mic also hears Ilan: its own
    /// first words leak back in short bursts before iOS's echo cancellation
    /// catches up (two "Let me." turns had 13 and 15 voiced frames over ~5 s).
    /// So a turn that starts while Ilan is talking needs 0.8 s of voice to
    /// interrupt Ilan or be sent at all; shorter speech is dropped. The user's
    /// real speech has about 30 voiced frames a second, so a real interruption
    /// gets through after roughly a second of talking.
    static let minBargeInVoicedFrames = 40
    /// Ilan was talking when this turn started (see `minBargeInVoicedFrames`).
    private var turnOverIlan = false
    private var turnVoiceNeeded: Int { turnOverIlan ? Self.minBargeInVoicedFrames : Self.minTurnVoicedFrames }
    private var turnVoicedFrames = 0
    /// How far into `conversationAudio` the turn's 20 ms frames have been counted.
    /// The phone sends tiny pieces (64 samples, under 3 ms), far shorter than a
    /// frame, so frames are counted over the turn's audio, not piece by piece.
    private var turnScanned = 0
    /// This turn has enough voice to count. (Read by the tests.)
    private(set) var turnIsSpeech = false
    private var turnStartedAt = Date()

    /// Each conversation turn as it ends (kept, or dropped and why), and the
    /// moment a turn interrupts Ilan, for the phone's connection log: so the
    /// bars above can be checked, and tuned, on real turns.
    var onTurn: (([String: Any]) -> Void)?
    private static func tenths(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    /// Enough voice in this turn: now it interrupts Ilan.
    private func countTurnVoice() {
        guard inTurn, !turnIsSpeech else { return }
        let frameBytes = 480 * 2
        while turnScanned + frameBytes <= conversationAudio.count {
            let start = conversationAudio.startIndex + turnScanned
            turnVoicedFrames += PCM.voicedFrames(conversationAudio[start..<start + frameBytes])
            turnScanned += frameBytes
        }
        guard turnVoicedFrames >= turnVoiceNeeded else { return }
        turnIsSpeech = true
        if turnOverIlan {
            onTurn?(["outcome": "interrupted Ilan", "afterSeconds": Self.tenths(Date().timeIntervalSince(turnStartedAt)),
                     "voicedFrames": turnVoicedFrames, "needed": turnVoiceNeeded])
        }
        interrupt()  // speaking over Ilan stops its reply
        phase = .recording
    }

    /// Off (push to talk: the app says when a turn ends) or semantic.
    private var turnDetection: Any { conversationActive ? Self.semanticTurns : NSNull() }

    /// OpenAI cleans up the phone's audio in a conversation (a phone held away
    /// from you, or on the table), so room noise is less likely to start a turn.
    private var noiseReduction: Any { conversationActive ? ["type": "far_field"] as [String: Any] : NSNull() }

    /// Listening between turns in a conversation, else ready.
    private var idlePhase: Phase { conversationActive ? .recording : .ready }

    /// The Mac's conversation is live on an iPhone: read-only here.
    var targetLiveOnPhone: Bool { !isRemote && target().map(store.liveOnPhone.contains) == true }
    static let liveOnPhoneMessage = "This conversation is live on your iPhone. You can follow it here, and talk again once the iPhone ends it."

    func startConversation() {
        guard !conversationActive else { return }
        errorMessage = nil
        interrupt()
        conversationActive = true
        remoteAway = false
        remoteHold = false
        if let id = target() { store.liveOnPhone.insert(id) }
        lastConversationAudio = Date()
        watchConversationAudio()
        conversationAudio = Data()
        inTurn = false
        ensureSession()  // a new session is configured for conversation from the start
        if sessionReady {
            client?.send(["type": "input_audio_buffer.clear"])
            sendTurnDetection()
        }
        do {
            try mic.start()
        } catch {
            errorMessage = error.localizedDescription
            stopConversation()
            return
        }
        phase = .recording
    }

    func stopConversation() {
        guard conversationActive else { return }
        interrupt()  // ending the conversation silences Ilan at once
        conversationActive = false
        remoteAway = false
        remoteHold = false
        turnReplies = []
        if let id = conversationID ?? target() { store.liveOnPhone.remove(id) }
        mic.stop()
        inputLevel = 0
        conversationAudio = Data()
        if sessionReady {
            client?.send(["type": "input_audio_buffer.clear"])
            sendTurnDetection()
        }
        if phase == .recording { phase = sessionReady ? .ready : (client == nil ? .offline : .connecting) }
    }

    /// A conversation streams audio all the time; none for this long means the
    /// phone's microphone is gone without a word (iOS took it for a call, say).
    /// A phone whose connection dropped is another matter: PhoneClient notices
    /// that first (its heartbeat gives up sooner than this), and the
    /// conversation waits for the phone instead (remoteDropped). So this must
    /// stay longer than the heartbeat's timeout. (Tests shorten it.)
    static let defaultConversationSilenceLimit: TimeInterval = 20
    var conversationSilenceLimit = defaultConversationSilenceLimit
    private var lastConversationAudio = Date()
    /// The phone's connection dropped mid-conversation; it may be back soon.
    private var remoteAway = false

    private func watchConversationAudio() {
        DispatchQueue.main.asyncAfter(deadline: .now() + min(1, conversationSilenceLimit / 4)) { [weak self] in
            guard let self, self.conversationActive else { return }
            if !self.remoteAway, Date().timeIntervalSince(self.lastConversationAudio) > self.conversationSilenceLimit {
                self.errorMessage = "Lost the iPhone's microphone, so the conversation ended."
                self.stopConversation()
            } else {
                self.watchConversationAudio()
            }
        }
    }

    // MARK: The iPhone's connection drops

    /// Where the phone was in Ilan's reply when it came back: the reply item
    /// it was on, how much of that item's audio had arrived (bytes), and how
    /// much of it was still waiting to play (ms).
    struct RemotePlayback: Equatable {
        var item: String?
        var bytes = 0
        var queuedMs = 0
    }
    /// Ilan's spoken replies since the user last spoke, in order (a turn's
    /// replies, with tool calls between, are kept whole), so a phone that
    /// dropped mid-reply can be played what it missed. Past the limit the
    /// oldest go. (Read by the tests.)
    private(set) var turnReplies: [(id: String, pcm: Data)] = []
    static let turnRepliesLimit = 6_000_000  // bytes, about two minutes
    /// The phone is away, or back and catching up: Ilan's reply goes on (and
    /// is kept in `turnReplies`) but isn't played until PhoneClient decides
    /// how to carry on (remoteResume or remoteSpokeOver).
    private(set) var remoteHold = false
    /// A reply resumed after the phone had gone quiet replays this much of
    /// what it already heard, so the sentence makes sense.
    static let resumeRewindBytes = 72_000  // 1.5 s
    /// Unit tests only: what remoteSpokeOver told the server was heard (item, ms).
    private(set) var lastRemoteTruncations: [(String, Int)] = []

    private func keepTurnReply(_ itemID: String, _ pcm: Data) {
        if let i = turnReplies.indices.last, turnReplies[i].id == itemID {
            turnReplies[i].pcm.append(pcm)
        } else {
            turnReplies.append((itemID, pcm))
        }
        var total = turnReplies.reduce(0) { $0 + $1.pcm.count }
        while total > Self.turnRepliesLimit, turnReplies.count > 1 { total -= turnReplies.removeFirst().pcm.count }
    }

    /// The phone's connection dropped mid-conversation (PhoneClient waits for
    /// it to come back). Its silence doesn't count meanwhile. Ilan's reply is
    /// not cut: it goes on, and is kept for when the phone is back.
    func remoteDropped() {
        guard conversationActive else { return }
        remoteAway = true
        remoteHold = true
    }

    /// The phone is back. `continuous`: it sends what it recorded while away,
    /// so its audio carries on where it left off and nothing is reset; then
    /// PhoneClient calls remoteResume or remoteSpokeOver. A page from before
    /// that: whatever was half-said is stale, so the next turn starts clean,
    /// and a reply the phone missed stays missed.
    func remoteReturned(continuous: Bool = false) {
        guard conversationActive else { return }
        remoteAway = false
        lastConversationAudio = Date()
        guard !continuous else { return }
        conversationAudio = Data()
        inTurn = false
        turnIsSpeech = false
        if sessionReady { client?.send(["type": "input_audio_buffer.clear"]) }
        if remoteHold {
            remoteHold = false
            interrupt()
        }
    }

    /// The phone is back and nothing was said meanwhile: play it what it
    /// missed of Ilan's reply, from where it was. If it had gone quiet, a
    /// little of what it already heard comes again first; if it was still
    /// playing, the rest follows on seamlessly. Replies that started while it
    /// was away follow, and the reply carries on live from there.
    func remoteResume(_ playback: RemotePlayback) {
        guard remoteHold else { return }
        remoteHold = false
        guard conversationActive, !turnReplies.isEmpty else { return }
        let replies = turnReplies
        var first = 0, offset = 0
        if let item = playback.item, let i = replies.firstIndex(where: { $0.id == item }) {
            let have = min(max(0, playback.bytes), replies[i].pcm.count) & ~1
            if have < replies[i].pcm.count {
                first = i
                offset = playback.queuedMs > 0 ? have : max(0, have - Self.resumeRewindBytes) & ~1
            } else {
                first = i + 1
            }
        }
        var replayed = false
        for k in first..<replies.count {
            let skip = k == first ? offset : 0
            speakingItemID = replies[k].id
            speakingItemStartFrame = speaker.enqueuedFrames - skip / 2
            let rest = replies[k].pcm.subdata(in: skip..<replies[k].pcm.count)
            if !rest.isEmpty {
                speaker.enqueue(rest)
                replayed = true
            }
        }
        if first >= replies.count, let last = replies.last {
            // The phone has all of it: more of this reply carries on from its end.
            speakingItemID = last.id
            speakingItemStartFrame = speaker.enqueuedFrames - last.pcm.count / 2
        }
        if replayed {
            phase = .speaking
            if !responseActive { speaker.flush() }
        }
    }

    /// The phone is back and the user spoke while it was away: their words
    /// come first, as if they had interrupted Ilan. The server is told how
    /// much of the reply was actually heard (of later replies: nothing), so
    /// Ilan knows what was missed; a reply still on its way is cancelled.
    func remoteSpokeOver(_ playback: RemotePlayback) {
        guard remoteHold else { return }
        remoteHold = false
        let replies = turnReplies
        let bytesPerMs = PCM.bytesPerSecond / 1000
        var cuts: [(String, Int)] = []
        var reached = -1  // the reply the phone was in
        if let item = playback.item, let i = replies.firstIndex(where: { $0.id == item }) {
            reached = i
            let heardMs = max(0, playback.bytes / bytesPerMs - playback.queuedMs)
            if let end = Self.truncationPoint(heardMs: heardMs, itemMs: replies[i].pcm.count / bytesPerMs) {
                cuts.append((item, end))
            }
        }
        for reply in replies[(reached + 1)...] { cuts.append((reply.id, 0)) }
        for (id, end) in cuts {
            client?.send(["type": "conversation.item.truncate", "item_id": id, "content_index": 0, "audio_end_ms": end])
        }
        lastRemoteTruncations = cuts
        speakingItemID = nil  // cut above, by what the phone actually heard
        interrupt()
    }

    private func sendTurnDetection() {
        client?.send(["type": "session.update", "session": [
            "type": "realtime", "audio": ["input": ["turn_detection": turnDetection, "noise_reduction": noiseReduction]],
            "tools": builtInTools(),  // end_conversation only while a conversation is on
        ]])
    }

    /// The conversation's audio since the last turn (plus a moment before the
    /// next one), so each turn is saved as its own recording.
    private var conversationAudio = Data()
    private var inTurn = false
    /// Kept from just before OpenAI noticed speech: it hears the start a moment late.
    static let turnLeadBytes = Int(PCM.sampleRate) * 2 / 2  // 0.5 s

    /// Cuts the finished turn's audio out of the conversation audio.
    private func takeTurnAudio() -> Data {
        let turn = conversationAudio
        conversationAudio = Data()
        inTurn = false
        return turn
    }

    // MARK: Push to talk

    // On the Mac, a single tap of the talk key stops Ilan; a double tap opens
    // the window and leaves Ilan alone. A press while Ilan is busy can't know
    // yet which it is, so it doesn't touch Ilan until that is clear:
    //   - held past a tap's length: the user is talking, stop Ilan;
    //   - a tap with no second tap within `secondTapWindow`: stop Ilan;
    //   - a double tap: `keepIlanGoing()`, nothing is stopped.
    // Meanwhile the microphone records quietly (nothing reaches OpenAI and the
    // phase stays as it is), so a press that turns out to be talking loses
    // none of its first words. The orb and the iPhone have no double tap: they
    // stop Ilan the moment they are pressed.

    /// How long after a tap a second tap may still come (the double-tap gap, plus a margin).
    static let secondTapWindow = DoubleTapDetector().maxGap + 0.05
    /// This session's timings: how long a press is held before it counts as
    /// talking, and how long after a tap a second tap may still come. The app
    /// uses the defaults; tests run the same sequences on shorter ones.
    var holdForTalk: TimeInterval = VoiceSession.minRecordingSeconds
    var tapStopDelay: TimeInterval = VoiceSession.secondTapWindow

    /// What the current (or last) press is, as far as stopping Ilan goes.
    private enum Press { case plain, undecided, talk, tap }
    private var press = Press.plain
    /// Counts presses, so a slow microphone-permission check acts only for its own press.
    private var pressCount = 0
    private var quietRecording = false
    /// Turns an undecided press that is still held into talking. Replacing
    /// either timer (or setting it to nil) cancels the old one.
    private var holdCheck: DispatchWorkItem? { didSet { oldValue?.cancel() } }
    /// Stops Ilan after a tap, unless a second tap comes first.
    private var tapStop: DispatchWorkItem? { didSet { oldValue?.cancel() } }

    /// Something a tap would stop: Ilan speaking, thinking or using tools, or a replay.
    private var ilanBusy: Bool {
        speaker.isPlaying || responseActive || clips.playingID != nil
            || phase == .speaking || phase == .working || phase == .thinking
    }

    private func after(_ delay: TimeInterval, _ action: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    /// A double tap: Ilan carries on with whatever it was doing.
    func keepIlanGoing() { forgetTap() }

    /// Calls off a tap's pending stop: something newer (a double tap, a stop,
    /// a replay, a typed message) decides what Ilan does now.
    private func forgetTap() { tapStop = nil }

    /// Held past a tap's length: the user is talking, so Ilan stops and the
    /// quiet recording becomes a real one.
    private func pressIsTalk() {
        holdCheck = nil
        guard press == .undecided, talkKeyHeld else { return }
        press = .talk
        interruptedThisPress = interrupt()
        if quietRecording {
            quietRecording = false
            goLive()
        }
    }

    /// A tap, and no second tap came: Ilan stops.
    private func stopAfterTap() {
        tapStop = nil
        pressEnded.send(interrupt() ? .stoppedSpeech : .discarded)
    }

    /// - Parameter waitForDoubleTap: true for the talk key, which double-taps
    ///   to open the window (see above).
    func pressToTalk(waitForDoubleTap: Bool = false) {
        guard phase != .recording else { return }
        guard !targetLiveOnPhone else { errorMessage = Self.liveOnPhoneMessage; return }
        errorMessage = nil
        livePress = false  // a new press: whatever the last one was is over
        pressCount += 1
        if waitForDoubleTap && (tapStop != nil || ilanBusy) {
            // Maybe a double tap, or its second half (the first tap's stop
            // now waits on this press): Ilan is left alone for now.
            press = .undecided
            interruptedThisPress = false
            forgetTap()
            holdCheck = after(holdForTalk) { [weak self] in self?.pressIsTalk() }
        } else {
            // Stop Ilan the instant the key goes down, even for a quick tap that
            // never becomes a recording. Remembered so the pill can say so.
            press = .plain
            interruptedThisPress = interrupt()
        }
        talkKeyHeld = true
        let thisPress = pressCount
        Task {
            guard await mic.requestPermission() else {
                errorMessage = "Ilan Voice needs microphone access (System Settings → Privacy & Security → Microphone)."
                return
            }
            // Pressed again while waiting (the permission prompt): that press has its own check.
            guard thisPress == pressCount else { return }
            // A quick press can be over before permission comes back: then
            // nothing is recorded. A tap reports once its wait is over.
            guard talkKeyHeld else {
                if press != .tap { pressEnded.send(interruptedThisPress ? .stoppedSpeech : .discarded) }
                return
            }
            beginRecording()
        }
    }

    /// How much audio of a reply has arrived so far, in milliseconds: still
    /// streaming (in `replyAudio`) or already saved with the message.
    private func receivedAudioMs(_ itemID: String) -> Int? {
        if let pcm = replyAudio[itemID] { return Int(PCM.seconds(pcm) * 1000) }
        guard let convID = conversationID, let seconds = store.message(convID, itemID)?.audioSeconds else { return nil }
        return Int(seconds * 1000)
    }

    /// Where to cut a reply the user interrupted, or nil when there is nothing
    /// to cut: if everything that arrived was already heard, OpenAI rejects
    /// the request ("Audio content of N ms is already shorter than M ms").
    static func truncationPoint(heardMs: Int, itemMs: Int?) -> Int? {
        guard let itemMs else { return heardMs }
        return heardMs < itemMs ? heardMs : nil
    }

    /// Silences Ilan right away: stops the speaker and any replayed clip,
    /// cancels the reply being generated, drops audio from it that is still on
    /// its way, skips the follow-up to any running tool call, and tells the
    /// server how much of the reply was actually heard.
    /// Returns true if there was something to stop.
    @discardableResult
    func interrupt() -> Bool {
        forgetTap()
        turnReplies = []  // a reply that was cut off is never played again
        // Asked for a reply that hasn't started yet: cancel it once it starts.
        let replyRequested = phase == .thinking && !responseActive
        if replyRequested { cancelNextResponse = true }
        let wasSpeaking = speaker.isPlaying || responseActive || replyRequested || phase == .speaking || phase == .working
        let wasReplaying = clips.playingID != nil
        clips.stop()
        guard wasSpeaking else { return wasReplaying }
        if let itemID = speakingItemID, let start = speakingItemStartFrame, client != nil {
            let heardMs = max(0, (speaker.playedFrames - start) * 1000 / Int(PCM.sampleRate))
            if let end = Self.truncationPoint(heardMs: heardMs, itemMs: receivedAudioMs(itemID)) {
                client?.send(["type": "conversation.item.truncate", "item_id": itemID,
                              "content_index": 0, "audio_end_ms": end])
            }
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
        if phase == .speaking || phase == .working || phase == .thinking {
            phase = conversationActive ? .recording : (sessionReady ? .ready : .offline)
        }
        return true
    }

    private func beginRecording() {
        bufferedAudio.removeAll()
        recording = Data()
        recordStart = Date()
        commitWhenReady = false
        do {
            try mic.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        microphoneName = mic.deviceName
        // Undecided: record quietly; nothing reaches OpenAI, nothing changes for Ilan.
        quietRecording = press == .undecided
        if !quietRecording { goLive() }
    }

    /// The press is for talking: OpenAI starts hearing it, from its first word.
    private func goLive() {
        livePress = true
        ensureSession()
        if sessionReady {
            client?.send(["type": "input_audio_buffer.clear"])
            refreshTranscriptionContext()
            if !recording.isEmpty { sendAudio(recording) }
        } else if !recording.isEmpty {
            bufferedAudio = [recording]
        }
        phase = .recording
    }

    /// Drops the recording in progress without sending it (the iPhone page's
    /// swipe up to cancel). Nothing reaches the model or the conversation.
    func cancelRecording() {
        talkKeyHeld = false
        guard phase == .recording else { return }
        mic.stop()
        finishingRecording = false
        recording = Data()
        bufferedAudio.removeAll()
        pendingUserAudio = nil
        commitWhenReady = false
        inputLevel = 0
        if sessionReady { client?.send(["type": "input_audio_buffer.clear"]) }
        endPress(.discarded)
        phase = sessionReady ? .ready : (client == nil ? .offline : .connecting)
    }

    func releaseToTalk() {
        talkKeyHeld = false
        if press == .undecided {
            // A tap: Ilan stops only if no second tap follows.
            press = .tap
            holdCheck = nil
            if quietRecording {
                quietRecording = false
                mic.stop()
                recording = Data()
                inputLevel = 0
            }
            tapStop = after(tapStopDelay) { [weak self] in self?.stopAfterTap() }
            return
        }
        guard phase == .recording, !finishingRecording else {
            if livePress && !finishingRecording { abandonPress() }
            return
        }
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
        guard phase == .recording else {
            if livePress { abandonPress() }
            return
        }
        inputLevel = 0
        // Ignore accidental taps: the API rejects buffers under ~100 ms anyway.
        // Silence (a press with nothing said) is dropped the same way, so it
        // never shows up in the conversation or reaches the model.
        guard PCM.seconds(recording) >= Self.minRecordingSeconds, PCM.containsSpeech(recording) else {
            if sessionReady { client?.send(["type": "input_audio_buffer.clear"]) }
            endPress(interruptedThisPress ? .stoppedSpeech : .discarded)
            phase = sessionReady ? .ready : (client == nil ? .offline : .connecting)
            return
        }
        endPress(.sent)
        // "Breeze" in System Settings → Sound; the file is still Blow.aiff.
        if !isRemote { NSSound(named: "Blow")?.play() }
        pendingUserAudio = recording
        phase = .thinking
        if sessionReady { commit() } else { commitWhenReady = true }
    }

    /// The press is live (OpenAI hears it) and hasn't said how it ended yet.
    /// Every live press ends with exactly one `pressEnded`: the floating pill
    /// waits for it to go away.
    private var livePress = false

    private func endPress(_ outcome: PressOutcome) {
        livePress = false
        pressEnded.send(outcome)
    }

    /// Something took the session over while the key was held, so this
    /// recording can't be sent: a dropped connection resending the message
    /// before it (which sets "Thinking"), or a reconnect (which sets
    /// "Offline"). Without this the key's release did nothing: the mic stayed
    /// on and the pill kept saying "Listening".
    private func abandonPress() {
        mic.stop()
        recording = Data()
        inputLevel = 0
        errorMessage = Self.lostPressMessage
        endPress(.discarded)  // the pill just goes (no "Stopped": Ilan may be about to answer the resent message)
    }
    static let lostPressMessage = "The connection to OpenAI was reset while you were talking, so that wasn't sent. Please say it again."

    private func handleMic(_ data: Data, _ level: Float) {
        if conversationActive {
            lastConversationAudio = Date()
            inputLevel = inputLevel * 0.6 + level * 0.4
            conversationAudio.append(data)
            countTurnVoice()
            // Between turns keep only the last moment, the start of the next turn.
            if !inTurn, conversationAudio.count > 2 * Self.turnLeadBytes {
                conversationAudio = conversationAudio.suffix(Self.turnLeadBytes)
            }
            // While (re)connecting, audio is dropped: stale speech mustn't start a turn later.
            if sessionReady { sendAudio(data) }
            return
        }
        guard phase == .recording || quietRecording else { return }
        inputLevel = inputLevel * 0.6 + level * 0.4
        recording.append(data)
        guard !quietRecording else { return }
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

    /// Internal (not private) so the unit tests can feed server events.
    func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String, let convID = conversationID else { return }
        if type != "session.created" && type != "session.updated" { cancelWatchdog() }
        defer { noteOwnMessages() }
        switch type {
        case "session.created":
            client?.send(sessionConfig())

        case "session.updated":
            guard !sessionReady else { return }
            sessionReady = true
            // Connected again: an earlier connection warning no longer applies.
            if let shown = connectionError, errorMessage == shown { errorMessage = nil }
            connectionError = nil
            bufferedAudio.forEach(sendAudio)
            bufferedAudio.removeAll()
            if let item = pendingTextItem {
                pendingTextItem = nil
                sendTextItem(item)
            } else if commitWhenReady {
                commitWhenReady = false
                commit()
            } else if phase == .connecting {
                phase = .ready
            }

        // Conversation mode: OpenAI heard the user start or finish a turn.
        case "input_audio_buffer.speech_started":
            guard conversationActive else { return }
            // Maybe speech, maybe noise: Ilan is only interrupted once the turn
            // has real voice in it (countTurnVoice).
            inTurn = true
            turnVoicedFrames = 0
            turnScanned = 0  // counts from the moment just before, kept in conversationAudio
            turnOverIlan = speaker.isPlaying || phase == .speaking
            turnIsSpeech = false
            turnStartedAt = Date()
            countTurnVoice()

        case "input_audio_buffer.speech_stopped":
            guard conversationActive, turnIsSpeech else { return }
            phase = .thinking

        case "input_audio_buffer.committed":
            unsentTurn = nil
            turnRetried = false
            guard let itemID = event["item_id"] as? String else { return }
            var msg = Message(id: itemID, role: .user, text: "", pending: true)
            if conversationActive {
                let confirmed = turnIsSpeech
                let voiced = PCM.voicedFrames(conversationAudio)
                let speech = confirmed || voiced >= turnVoiceNeeded
                turnIsSpeech = false
                onTurn?(["outcome": speech ? "kept" : "dropped: too little voice", "item": itemID,
                         "voicedFrames": voiced, "needed": turnVoiceNeeded, "overIlan": turnOverIlan,
                         "seconds": Self.tenths(PCM.seconds(conversationAudio)),
                         "turnSeconds": Self.tenths(Date().timeIntervalSince(turnStartedAt))])
                guard speech else {
                    // Noise: forget the turn here and at OpenAI; Ilan carries on.
                    _ = takeTurnAudio()
                    client?.send(["type": "conversation.item.delete", "item_id": itemID])
                    return
                }
                if !confirmed { interrupt() }  // only now known to be speech
                turnReplies = []  // a new turn: earlier replies are done with
                phase = .thinking
                client?.send(["type": "response.create"])
                // Transcribed live like a push-to-talk turn; Luna repairs it once Ilan has answered.
                pendingUserAudio = takeTurnAudio()
            }
            if let pcm = pendingUserAudio {
                let file = "\(itemID).wav"
                try? PCM.wav(pcm).write(to: store.audioURL(convID, file))
                msg.audioFile = file
                msg.audioSeconds = PCM.seconds(pcm)
                pendingUserAudio = nil
            }
            store.update(convID) { conv in
                Self.settleEarlierCorrections(&conv)
                conv.messages.append(msg)
            }

        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = event["item_id"] as? String, let delta = event["delta"] as? String else { return }
            store.updateMessage(convID, itemID) { $0.text += delta }

        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = event["item_id"] as? String else { return }
            let text = (event["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                if conversationActive { onTurn?(["outcome": "dropped: no words", "item": itemID]) }
                discardSilentTurn(convID, itemID)
                return
            }
            store.updateMessage(convID, itemID) {
                $0.text = text
                $0.pending = false
                $0.awaitingCorrection = true  // grey until Luna has had its go
            }
            correctTranscript(convID)

        case "conversation.item.input_audio_transcription.failed":
            guard let itemID = event["item_id"] as? String else { return }
            store.updateMessage(convID, itemID) { $0.text = "(transcription failed)"; $0.pending = false }
            retitleWhenSettled(convID)

        case "response.created":
            currentResponseID = (event["response"] as? [String: Any])?["id"] as? String
            if cancelNextResponse {
                cancelNextResponse = false
                mutedResponseID = currentResponseID
                client?.send(["type": "response.cancel"])
                return
            }
            responseActive = true

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
                if isRemote && conversationActive { keepTurnReply(itemID, pcm) }
                if remoteHold {
                    phase = .speaking  // kept for the phone, played when it is back
                    return
                }
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
            retitleWhenSettled(convID)

        case "response.done":
            let response = event["response"] as? [String: Any] ?? [:]
            // Billed even when the user cut it off, so recorded first.
            recordReplyUsage(convID, response)
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
            } else {
                if !speaker.isPlaying { phase = idlePhase }
                // Ilan's whole answer (replies and tool calls) is in: fix the transcript.
                correctTranscript(convID)
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
            // Cutting a reply at a point it already ended at is harmless too.
            if message.contains("is already shorter than") { return }
            // A reply that failed to start won't need cancelling.
            cancelNextResponse = false
            // OpenAI ends every session after 60 minutes. That is routine: start
            // a fresh one quietly (the conversation is carried over as text),
            // unless a reply was on its way, which the user should hear about.
            if Self.isSessionExpiry(code: error?["code"] as? String, message: message) {
                let busy = responseActive || phase == .thinking || phase == .working || phase == .speaking
                if !busy {
                    // A conversation keeps going on the fresh session.
                    if phase != .recording || conversationActive { connect() }
                    return
                }
            }
            errorMessage = message
            if phase == .thinking || phase == .connecting { phase = sessionReady ? .ready : .offline }

        default:
            break
        }
    }

    /// After each finished, transcribed reply, ask the title model for a fresh
    /// name. Only the newest request per conversation may apply its result.
    private var titleRequests: [UUID: Int] = [:]

    /// Unit tests only: stand in for the title model and the transcript fixer.
    var titleOverride: (@MainActor (_ messages: [Message]) async -> String?)?
    var transcriptFixOverride: (@MainActor (_ transcript: String) async -> String?)?

    /// Names the conversation only once the user's latest message is final:
    /// transcribed and, when spoken, corrected by Luna (correctTranscript
    /// calls this when it is done). Otherwise the title could be built from
    /// misheard words.
    private func retitleWhenSettled(_ convID: UUID) {
        guard let conv = store.conversations.first(where: { $0.id == convID }) else { return }
        if let user = conv.messages.last(where: { $0.role == .user }), user.pending || user.awaitingCorrection == true { return }
        retitle(convID)
    }

    private func retitle(_ convID: UUID) {
        guard let conv = store.conversations.first(where: { $0.id == convID }), conv.titleLocked != true else { return }
        let ticket = (titleRequests[convID] ?? 0) + 1
        titleRequests[convID] = ticket
        let messages = conv.messages
        let key = settings.apiKey
        let model = settings.titleModel
        Task {
            let title: String?
            if let titleOverride { title = await titleOverride(messages) }
            else { title = await ConversationTitler.title(for: messages, apiKey: key, model: model) }
            guard let title, titleRequests[convID] == ticket else { return }
            store.setAutoTitle(convID, title)
        }
    }

    // MARK: Usage and cost

    /// Records a reply's tokens for the conversation's cost, and shows them on
    /// the message it produced (with any earlier tool-calling steps).
    private func recordReplyUsage(_ convID: UUID, _ response: [String: Any]) {
        guard let raw = response["usage"] as? [String: Any] else { return }
        let tokens = TokenUsage.realtime(raw)
        store.recordUsage(convID, UsageRecord(model: sessionModel.isEmpty ? settings.model : sessionModel, tokens: tokens))
        let total = unshownReplyUsage + tokens
        let said = (response["output"] as? [[String: Any]] ?? []).last { $0["type"] as? String == "message" }
        guard let itemID = said?["id"] as? String, store.message(convID, itemID) != nil else {
            unshownReplyUsage = total
            return
        }
        unshownReplyUsage = TokenUsage()
        store.updateMessage(convID, itemID) { $0.usage = total }
    }

    /// User messages already sent for correction (each one only once).
    private var correctedTranscripts: Set<String> = []

    /// Only the latest message is ever corrected, so when a new one starts,
    /// any earlier message still waiting (its turn was cut off or failed) is final.
    static func settleEarlierCorrections(_ conv: inout Conversation) {
        for i in conv.messages.indices where conv.messages[i].awaitingCorrection == true {
            conv.messages[i].awaitingCorrection = nil
        }
    }

    /// Once the user's latest message is transcribed and Ilan's whole answer
    /// is done (final reply after any tool calls), a text model fixes misheard
    /// words using the dictionary, the recent conversation, Ilan's tool calls
    /// and replies. The raw transcript is kept in `rawText`. Runs from either
    /// event (transcript done, final response done), whichever comes last.
    /// The conversation is renamed after it, from the corrected words.
    private func correctTranscript(_ convID: UUID) {
        let finished = !responseActive && phase != .thinking && phase != .working
        guard let conv = store.conversations.first(where: { $0.id == convID }),
              let turn = TranscriptFixer.turnToCorrect(conv.messages, done: correctedTranscripts,
                                                       turnFinished: finished) else { return }
        let user = turn.user
        let reply = turn.replies.map(\.text).joined(separator: "\n")
        correctedTranscripts.insert(user.id)
        let history = Array(conv.messages.prefix { $0.id != user.id })
        let key = settings.apiKey, model = settings.titleModel, terms = UserDictionary.terms()
        Task {
            let fixed: String?
            if let transcriptFixOverride { fixed = await transcriptFixOverride(user.text) }
            else { fixed = await TranscriptFixer.fix(user.text, dictionary: terms, history: history,
                                                     tools: turn.tools, reply: reply, apiKey: key, model: model) }
            // Final either way: corrected, unchanged, or every attempt failed.
            store.updateMessage(convID, user.id) { message in
                message.awaitingCorrection = nil
                guard let fixed, message.text == user.text else { return }  // edited meanwhile
                message.rawText = message.rawText ?? message.text
                message.text = fixed
            }
            retitleWhenSettled(convID)  // now the title can use the corrected words
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

    // MARK: Ending a conversation by voice

    static let endConversationName = "end_conversation"
    static var endConversationDefinition: [String: Any] {
        [
            "type": "function",
            "name": endConversationName,
            "description": """
            End this live voice conversation: the user's iPhone stops listening and plays its \
            closing sound. NEVER call this unless the user has clearly said they want to end, \
            finish, close or stop the conversation (for example "let's end this conversation"). \
            Pauses, silence, thanks, "that's all for now" without asking to end, or finishing \
            a task are NOT reasons to call it; if unsure, ask. When the user does ask to end, tell \
            them in a few words that you're ending the conversation, such as "OK, ending the \
            conversation now.", then call this tool. No goodbye is needed.
            """,
            "parameters": ["type": "object", "properties": [String: Any]()] as [String: Any],
        ]
    }
    /// Set while a tool batch contains end_conversation.
    private var endRequested = false
    /// Tells the iPhone page that Ilan ended the conversation (it plays the closing sound).
    var onConversationEndedByIlan: (() -> Void)?

    /// Waits for Ilan's goodbye to finish playing (at most 15 s), then ends the conversation.
    private func endConversationAfterGoodbye() {
        let deadline = Date().addingTimeInterval(15)
        func check() {
            guard conversationActive else { return }  // the user ended it meanwhile
            if (speaker.isPlaying || responseActive) && Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
                return
            }
            onConversationEndedByIlan?()
            stopConversation()
        }
        check()
    }

    /// Unit tests only: runs every tool call instead of the real tools.
    var toolOverride: (@MainActor (_ name: String, _ arguments: String) async -> String)?

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
                        case Self.endConversationName where self.conversationActive:
                            self.endRequested = true
                            output = "The conversation ends as soon as what you just said has finished playing."
                        case _ where self.toolOverride != nil: output = await self.toolOverride!(name, args)
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
            // Asked to end the conversation: no follow-up reply, just let the goodbye finish.
            if endRequested {
                endRequested = false
                endConversationAfterGoodbye()
                return
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
    /// Internal (not private) so the unit tests can check which tools Ilan gets.
    /// What a session is configured with: the settings, plus the MCP tools it
    /// was given. When either changes (e.g. the MCP servers were reloaded in
    /// Settings), the next press starts a fresh session with the new tools.
    private var sessionFingerprint: String {
        settings.sessionFingerprint + "|" + mcp.tools.map(\.functionName).joined(separator: ",")
    }

    /// Reconnect (the header's button, ⇧⌘R): restarts every MCP server, so
    /// changes to mcp.json or to the servers themselves take effect, then
    /// starts a fresh session with their tools. The conversation is kept.
    func reconnect() async {
        guard !mcp.loading else { return }
        await mcp.reload()
        connect()
    }

    func builtInTools() -> [[String: Any]] {
        var tools: [[String: Any]] = mcp.realtimeTools
        // Only during a live iPhone conversation: hands-free, so it can be ended by voice.
        if isRemote && conversationActive { tools.append(Self.endConversationDefinition) }
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
        forgetTap()  // chosen after a tap: the tap's late stop mustn't cut it
        speaker.stop()
        store.updateMessage(convID, message.id) { $0.listened = true }
        clips.toggle(id: message.id, url: store.audioURL(convID, file))
    }

    /// Plays the assistant reply heard most recently again from the start,
    /// cutting off anything Ilan is saying now. Not while the talk key is down.
    func replayLast() {
        guard !talkKeyHeld, let last = clips.lastPlayed, FileManager.default.fileExists(atPath: last.url.path) else { return }
        interrupt()
        clips.stop()
        clips.toggle(id: last.id, url: last.url)
    }

    /// Plays the oldest reply the user has not heard yet, then the next one.
    func playNextUnheard() {
        forgetTap()  // chosen after a tap: the tap's late stop mustn't cut it
        playUnheard()
    }

    private func playUnheard() {
        guard let conv = store.selected,
              let next = conv.messages.first(where: { $0.role == .assistant && !$0.listened && $0.audioFile != nil }) else { return }
        let convID = conv.id
        store.updateMessage(convID, next.id) { $0.listened = true }
        clips.toggle(id: next.id, url: store.audioURL(convID, next.audioFile!)) { [weak self] in
            self?.playUnheard()
        }
    }
}
