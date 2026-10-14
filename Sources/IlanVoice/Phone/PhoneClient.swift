import Combine
import Foundation

/// One iPhone: its voice session, its conversation and its live connection.
/// Phones are told apart by a random device ID the web page keeps, so each
/// one talks in its own conversation and they can be used at the same time.
///
/// The connection comes and goes with the phone's network (a tunnel, a Wi-Fi
/// hand-off). Tailscale keeps a dead connection open for a long time, so the
/// Mac pings the page and drops a connection that stays silent; and a
/// conversation survives a drop: it waits (`awayLimit`) for the same page to
/// come back and carry on, instead of ending the moment the phone is gone.
@MainActor
final class PhoneClient {
    /// How often the page is pinged, and how long without a word from it (a
    /// pong, audio, a command) before its connection counts as dead.
    /// (Tests shorten these.)
    static var heartbeatInterval: TimeInterval = 2
    static var heartbeatTimeout: TimeInterval = 5
    /// How long a conversation waits for a dropped phone to come back.
    static var awayLimit: TimeInterval = 120

    let device: String
    let session: VoiceSession
    var onConnectionChange: (() -> Void)?
    var isConnected: Bool { peer != nil }
    /// The phone dropped mid-conversation; the conversation is waiting for it.
    private(set) var isAway = false

    private let store: ConversationStore
    private let input = RemoteMicrophone()
    private let output = RemoteSpeaker()
    private var peer: WebSocketPeer?
    private var heartbeat: Timer?
    private var lastHeard = Date()
    private var awayTimer: DispatchWorkItem? { didSet { oldValue?.cancel() } }
    private var cuttingReply = false
    private var conversationID: UUID?
    private var cancellables: Set<AnyCancellable> = []
    private var lastSentMessages: [[String: Any]] = []

    init(device: String, store: ConversationStore, mcp: MCPManager) {
        self.device = device
        self.store = store
        var target: (() -> UUID?)?
        session = VoiceSession(store: store, mcp: mcp, input: input, output: output, isRemote: true,
                               target: { target?() })
        target = { [weak self] in self?.conversation(create: true) }
        conversationID = store.iPhoneConversation(device: device, create: false)

        output.sendAudio = { [weak self] pcm in
            guard let self else { return }
            if let peer = self.peer { peer.send(binary: pcm); return }
            // A reply that starts while the phone is away can't be heard: cut it
            // (once the session has finished handling this piece of it).
            guard self.isAway, !self.cuttingReply else { return }
            self.cuttingReply = true
            DispatchQueue.main.async { self.cuttingReply = false; self.session.interrupt() }
        }
        output.sendStop = { [weak self] in self?.peer?.send(json: ["type": "audio_stop"]) }
        session.onConversationEndedByIlan = { [weak self] in self?.peer?.send(json: ["type": "conversation_ended"]) }
        session.$phase.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sendState() } }
            .store(in: &cancellables)
        session.$errorMessage.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sendState() } }
            .store(in: &cancellables)
        AppSettings.shared.$showUsage.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sendMessages(force: true) } }
            .store(in: &cancellables)
        store.$conversations
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendMessages() }
            .store(in: &cancellables)
    }

    /// A page for this phone connected, `conversing` as far as it knows. The
    /// conversation goes on only if both sides think so: the page that
    /// dropped and is back carries on; a page that ended it while away, or a
    /// new window, ends it; and a page that still thinks it is conversing
    /// when the Mac has let the conversation go is told so in hello_ok, and ends.
    func attach(_ newPeer: WebSocketPeer, conversing: Bool) {
        if let old = peer, old !== newPeer {
            // A newer window for the same phone takes over (or the same page is
            // back before its old connection was found dead): the old one is
            // told so and does not reconnect on its own (otherwise the two
            // would keep swapping).
            old.onClose = nil
            old.send(json: ["type": "replaced"])
            old.close()
        }
        peer = newPeer
        awayTimer = nil
        if session.conversationActive, !conversing { session.stopConversation() }
        if isAway {
            isAway = false
            session.remoteReturned()
        }
        newPeer.onBinary = { [weak self, weak newPeer] data in
            guard let self, newPeer === self.peer else { return }
            self.lastHeard = Date()
            self.input.deliver(data)
        }
        newPeer.onText = { [weak self, weak newPeer] text in
            guard let self, newPeer === self.peer else { return }
            self.lastHeard = Date()
            self.handleText(text)
        }
        newPeer.onClose = { [weak self, weak newPeer] in
            guard let self, newPeer === self.peer else { return }
            self.peer = nil
            self.stopHeartbeat()
            if self.session.conversationActive {
                // Mid-conversation: the phone may well be back in a moment, so
                // the conversation waits for it rather than ending.
                self.isAway = true
                self.session.remoteDropped()
                let work = DispatchWorkItem { [weak self] in self?.awayTooLong() }
                self.awayTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.awayLimit, execute: work)
            } else if self.session.phase == .recording {
                self.session.releaseToTalk()
            }
            self.onConnectionChange?()
        }
        lastHeard = Date()
        startHeartbeat()
        lastSentMessages = []
        newPeer.send(json: ["type": "hello_ok", "conversing": session.conversationActive])
        sendMessages(force: true)
        sendState()
        onConnectionChange?()
    }

    /// The phone never came back: the conversation ends after all.
    private func awayTooLong() {
        guard isAway else { return }
        isAway = false
        session.stopConversation()
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    /// Pings the page. A page silent for too long has lost the Mac, whatever
    /// the connection says (iOS and Tailscale can take minutes to notice): it
    /// is dropped here, which goes like any other drop (onClose above).
    private func beat() {
        guard let peer else { return }
        if Date().timeIntervalSince(lastHeard) > Self.heartbeatTimeout { peer.drop(); return }
        peer.send(json: ["type": "ping"])
    }

    /// The Mac cuts this phone off (a new pairing code): its conversation ends too.
    func disconnect() {
        session.stopConversation()
        peer?.close()
    }

    func shutDown() {
        session.stopConversation()
        peer?.close()
        peer = nil
        stopHeartbeat()
        awayTimer = nil
        isAway = false
        session.disconnect()
    }

    /// A message from the page: a command, or a viewport report.
    private func handleText(_ text: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }
        if type == "viewport" { logViewport(obj); return }
        command(type)
    }

    /// Unit tests only: a message as if the page had sent it.
    func receiveForTesting(_ text: String) { handleText(text) }

    /// The page's screen and viewport sizes, one JSON line per report, in
    /// phone-viewport.log next to agent.md: for diagnosing iOS layout bugs
    /// (like a page shorter than the screen) on a phone we can't look at.
    static var viewportLog: URL { Paths.root.appendingPathComponent("phone-viewport.log") }

    private func logViewport(_ report: [String: Any]) {
        var entry = report
        entry["time"] = ISO8601DateFormatter().string(from: Date())
        entry["device"] = device
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: Self.viewportLog) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            try? line.write(to: Self.viewportLog)
        }
    }

    private func command(_ type: String) {
        switch type {
        case "conversation_start": session.startConversation()
        case "conversation_stop": session.stopConversation()
        case "press": session.pressToTalk()
        case "release": session.releaseToTalk()
        case "cancel": session.cancelRecording()
        case "reconnect": reconnect()
        case "stop": session.interrupt()
        case "replay": replayLast()
        case "new_phone": _ = PhoneServer.number(for: device)  // "This is a new iPhone"
        default: break
        }
    }

    /// This phone's conversation. It is only created when the phone first
    /// talks, so opening the page without talking leaves nothing behind.
    /// Deleting it on the Mac means the next press starts a fresh one.
    private func conversation(create: Bool) -> UUID? {
        if let id = conversationID, store.conversations.contains(where: { $0.id == id }) { return id }
        conversationID = store.iPhoneConversation(device: device, create: create)
        return conversationID
    }

    /// The page's Reconnect button: a fresh OpenAI session for this phone's
    /// conversation, like Voice → Reconnect on the Mac. Ignored mid-recording.
    func reconnect() {
        guard session.phase != .recording else { return }
        session.connect()
    }

    /// Plays Ilan's latest reply again on this phone.
    private func replayLast() {
        guard let convID = conversation(create: false),
              let conv = store.conversations.first(where: { $0.id == convID }),
              let last = conv.messages.last(where: { $0.role == .assistant && $0.audioFile != nil }),
              let wav = try? Data(contentsOf: store.audioURL(convID, last.audioFile!)), wav.count > 44 else { return }
        session.interrupt()
        peer?.send(json: ["type": "audio_stop"])
        let pcm = wav.dropFirst(44)
        let chunk = 48_000  // half a second
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let end = min(offset + chunk, pcm.endIndex)
            peer?.send(binary: Data(pcm[offset..<end]))
            offset = end
        }
    }

    private func sendState() {
        guard let peer else { return }
        // The phone's voice session only dials OpenAI on the first press, so
        // until then it is "offline" while everything is in fact connected and
        // a press works right away: show that as Ready. (If the phone loses
        // the Mac, the page itself shows Reconnecting.)
        let label = session.phase == .offline ? VoiceSession.Phase.ready.label : session.phase.label
        var state: [String: Any] = ["type": "state", "phase": label,
                                    "busy": session.phase != .ready && session.phase != .offline]
        if let error = session.errorMessage { state["error"] = error }
        peer.send(json: state)
    }

    private func sendMessages(force: Bool = false) {
        guard let peer else { return }
        let conv = conversation(create: false).flatMap { id in store.conversations.first { $0.id == id } }
        // Costs and token counts follow the Mac's "Show conversation costs and
        // token counts" setting.
        let showUsage = AppSettings.shared.showUsage
        let items: [[String: Any]] = (conv?.messages ?? []).suffix(80).map { m in
            switch m.role {
            case .user, .assistant:
                var item: [String: Any] = ["id": m.id, "role": m.role == .user ? "user" : "assistant", "text": m.text, "pending": m.pending]
                if showUsage, m.role == .assistant, let usage = m.usage { item["usage"] = Pricing.describe(usage) }
                return item
            case .tool:
                return ["id": m.id, "role": "tool", "text": m.toolName ?? "tool", "pending": m.pending]
            }
        }
        var cost: String?
        if showUsage, let conv, conv.usage?.isEmpty == false {
            cost = Pricing.format(conv.cost.dollars, incomplete: conv.cost.incomplete)
        }
        var all = items
        all.append(["cost": cost ?? ""])  // so a change in cost alone is sent too
        guard force || !NSArray(array: all).isEqual(to: lastSentMessages) else { return }
        lastSentMessages = all
        var payload: [String: Any] = ["type": "messages", "title": conv?.title ?? "Ilan Voice", "items": items]
        if let cost { payload["cost"] = cost }
        peer.send(json: payload)
    }
}
