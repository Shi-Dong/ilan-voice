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
    /// The timeout is generous: on a train's Wi-Fi the network often stalls
    /// for several seconds and then delivers everything late, and riding that
    /// out beats reconnecting. (The page gives up after as long; see SILENCE_MS.)
    static var heartbeatInterval: TimeInterval = 2
    static var heartbeatTimeout: TimeInterval = 15
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
    private var conversationID: UUID?
    private var cancellables: Set<AnyCancellable> = []
    private var lastSentMessages: [[String: Any]] = []
    /// Why the Mac is about to drop the connection (nil: the network or the page closed it).
    private var dropReason: String?
    /// Reply audio sent to the page lately (when, how many bytes), for the log.
    private var recentAudio: [(Date, Int)] = []

    // Nothing lost on a bad network. Both directions are counted, so a page
    // that comes back is sent exactly what it missed, and sends exactly what
    // the Mac missed:
    // - its microphone: the page numbers its audio (micSent) and keeps the
    //   last minute of it, including all it records while away; hello_ok says
    //   how much arrived here (micReceived), and the page sends the rest first
    //   (its catch-up);
    // - Ilan's reply: each reply item's audio is announced to the page
    //   ("reply", with where in the item it starts), the page counts what
    //   arrives and says in its hello where it was; the session keeps the
    //   turn's replies and plays the phone the rest (remoteResume).
    // Until the catch-up is in, the reply is held: if the user spoke while
    // away, their words come first (remoteSpokeOver), otherwise the reply
    // carries on.

    /// Microphone audio received from the page in this conversation (bytes).
    private(set) var micReceived = 0
    /// A page that came back mid-conversation: where it was in the reply, and
    /// its catch-up audio as it arrives.
    private var catchUp: CatchUp?
    private struct CatchUp {
        var playback: VoiceSession.RemotePlayback
        var receiving = false
        var audio = Data()
        var lostBytes = 0
    }
    private var catchUpTimer: DispatchWorkItem? { didSet { oldValue?.cancel() } }
    /// How long to wait for a page's catch-up (from its return, then from
    /// each piece of it) before carrying on without the rest. (Tests shorten it.)
    static var catchUpTimeout: TimeInterval = 15
    /// Speech while away means at least this much voice (as when interrupting
    /// Ilan, VoiceSession.minBargeInVoicedFrames) within any 3 s.
    static let gapSpeechWindowFrames = 150
    /// The catch-up goes to the session in pieces this size (0.1 s), like live audio.
    static let catchUpPiece = 4_800
    /// The reply item the page has been told it is getting, on this connection.
    private var markedItem: String?

    init(device: String, store: ConversationStore, mcp: MCPManager) {
        self.device = device
        self.store = store
        var target: (() -> UUID?)?
        session = VoiceSession(store: store, mcp: mcp, input: input, output: output, isRemote: true,
                               target: { target?() })
        target = { [weak self] in self?.conversation(create: true) }
        conversationID = store.iPhoneConversation(device: device, create: false)

        output.sendAudio = { [weak self] pcm in
            // While the phone is away the session holds the reply instead (remoteDropped).
            guard let self, let peer = self.peer else { return }
            // A new reply item, or the first audio on this connection: say which
            // one and where in it this audio starts, so the page knows where it is.
            if let item = self.session.speakingItemID, item != self.markedItem {
                let chunkStart = self.output.enqueuedFrames - pcm.count / 2
                let itemStart = self.session.speakingItemStartFrame ?? chunkStart
                peer.send(json: ["type": "reply", "item": item, "at": max(0, chunkStart - itemStart) * 2])
                self.markedItem = item
            }
            peer.send(binary: pcm)
            let now = Date()
            self.recentAudio.append((now, pcm.count))
            if let first = self.recentAudio.first, now.timeIntervalSince(first.0) > 20 {
                self.recentAudio.removeAll { now.timeIntervalSince($0.0) > 10 }
            }
        }
        output.sendStop = { [weak self] in
            self?.markedItem = nil
            self?.peer?.send(json: ["type": "audio_stop"])
        }
        session.onConversationEndedByIlan = { [weak self] in self?.peer?.send(json: ["type": "conversation_ended"]) }
        session.onTurn = { [weak self] report in self?.log("turn", report) }
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

    /// A page for this phone connected (its `hello`), `conversing` as far as
    /// it knows. The conversation goes on only if both sides think so: the
    /// page that dropped and is back carries on; a page that ended it while
    /// away, or a new window, ends it; and a page that still thinks it is
    /// conversing when the Mac has let the conversation go is told so in
    /// hello_ok, and ends.
    func attach(_ newPeer: WebSocketPeer, hello: [String: Any]) {
        let conversing = hello["conversing"] as? Bool ?? false
        // A page from this version counts and keeps its microphone audio.
        let canCatchUp = hello["micSent"] as? Int != nil
        var entry: [String: Any] = ["pageConversing": conversing, "macConversing": session.conversationActive, "wasAway": isAway]
        if let report = hello["drop"] as? [String: Any] { entry["previousDrop"] = report }  // the page's side of the last drop
        if let playback = hello["playback"] as? [String: Any] { entry["playback"] = playback }
        if let micSent = hello["micSent"] as? Int { entry["micSent"] = micSent; entry["micReceived"] = micReceived }
        log("connected", entry)
        if let old = peer, old !== newPeer {
            log("replaced", ["why": "a newer connection from this phone"])
            // A newer window for the same phone takes over (or the same page is
            // back before its old connection was found dead): the old one is
            // told so and does not reconnect on its own (otherwise the two
            // would keep swapping).
            old.onClose = nil
            old.send(json: ["type": "replaced"])
            old.close()
        }
        peer = newPeer
        markedItem = nil
        awayTimer = nil
        catchUp = nil
        catchUpTimer = nil
        if session.conversationActive, !conversing { session.stopConversation() }
        if session.conversationActive && conversing && canCatchUp {
            if !isAway {
                // Back before the Mac noticed the drop: what was sent meanwhile
                // went nowhere, so it is handled as a drop and return.
                output.forgetPlayback()
                session.remoteDropped()
            }
            isAway = false
            session.remoteReturned(continuous: true)
            catchUp = CatchUp(playback: Self.playback(hello["playback"]))
            armCatchUpTimer()
        } else if isAway {
            isAway = false
            session.remoteReturned()
        }
        newPeer.onBinary = { [weak self, weak newPeer] data in
            guard let self, newPeer === self.peer else { return }
            self.lastHeard = Date()
            if self.catchUp?.receiving == true {
                self.catchUp?.audio.append(data)
                self.armCatchUpTimer()  // still coming: a slow network gets its time
                return
            }
            if self.session.conversationActive { self.micReceived += data.count }
            self.input.deliver(data)
        }
        newPeer.onText = { [weak self, weak newPeer] text in
            guard let self, newPeer === self.peer else { return }
            self.lastHeard = Date()
            self.handleText(text)
        }
        newPeer.onClose = { [weak self, weak newPeer] in
            guard let self, newPeer === self.peer else { return }
            self.log("dropped", ["why": self.dropReason ?? "closed (network or page)",
                                 "silentSeconds": Self.round(Date().timeIntervalSince(self.lastHeard)),
                                 "replyAudioSecondsLast10s": self.recentReplySeconds()])
            self.dropReason = nil
            self.peer = nil
            self.markedItem = nil
            // A catch-up cut short isn't counted: the page sends it again.
            self.catchUp = nil
            self.catchUpTimer = nil
            self.stopHeartbeat()
            if self.session.conversationActive {
                // Mid-conversation: the phone may well be back in a moment, so
                // the conversation waits for it rather than ending.
                self.isAway = true
                self.output.forgetPlayback()  // what was on its way is lost
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
        newPeer.send(json: ["type": "hello_ok", "conversing": session.conversationActive, "micReceived": micReceived])
        sendMessages(force: true)
        sendState()
        onConnectionChange?()
    }

    /// The phone never came back: the conversation ends after all.
    private func awayTooLong() {
        guard isAway else { return }
        log("conversation ended", ["why": "the phone stayed away \(Int(Self.awayLimit)) s"])
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
        if Date().timeIntervalSince(lastHeard) > Self.heartbeatTimeout {
            dropReason = "silent: no answer to pings for \(Self.round(Date().timeIntervalSince(lastHeard))) s"
            peer.drop()
            return
        }
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
        if type == "diag" { logPage(obj); return }
        if type == "catchup" {
            catchUp?.receiving = true
            catchUp?.lostBytes = obj["lost"] as? Int ?? 0
            return
        }
        if type == "catchup_end" { finishCatchUp(timedOut: false); return }
        command(type)
    }

    private func armCatchUpTimer() {
        let work = DispatchWorkItem { [weak self] in self?.finishCatchUp(timedOut: true) }
        catchUpTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.catchUpTimeout, execute: work)
    }

    /// The page's catch-up is in (or never came): did the user speak while
    /// the phone was away? Then their words come first; otherwise Ilan's
    /// reply carries on from where the phone was. Either way the audio then
    /// goes to the session, as if it had arrived live.
    private func finishCatchUp(timedOut: Bool) {
        guard let c = catchUp else { return }
        catchUp = nil
        catchUpTimer = nil
        micReceived += c.audio.count
        let spoke = PCM.densestVoice(c.audio, windowFrames: Self.gapSpeechWindowFrames) >= VoiceSession.minBargeInVoicedFrames
        log("caught up", ["seconds": Self.round(PCM.seconds(c.audio)), "lostSeconds": Self.round(Double(c.lostBytes) / Double(PCM.bytesPerSecond)),
                          "spoke": spoke, "timedOut": timedOut,
                          "playback": ["item": c.playback.item ?? "", "bytes": c.playback.bytes, "queuedMs": c.playback.queuedMs]])
        if spoke {
            markedItem = nil
            peer?.send(json: ["type": "audio_stop"])
            session.remoteSpokeOver(c.playback)
        } else {
            var still = Double(c.playback.queuedMs) / 1000
            if still > 0, let item = c.playback.item, !session.turnReplies.contains(where: { $0.id == item }) {
                // Still playing a reply the Mac has let go of (Ilan was stopped and
                // the stop got lost with the connection): stop it first.
                markedItem = nil
                peer?.send(json: ["type": "audio_stop"])
                still = 0
            }
            output.forgetPlayback(stillQueued: still)
            session.remoteResume(c.playback)
        }
        var at = 0
        while at < c.audio.count {
            let end = min(c.audio.count, at + Self.catchUpPiece)
            input.deliver(c.audio.subdata(in: at..<end))
            at = end
        }
    }

    /// The page's "playback" in its hello: the reply item it was on, the bytes
    /// of it that had arrived, and the milliseconds of it still to play.
    static func playback(_ value: Any?) -> VoiceSession.RemotePlayback {
        let d = value as? [String: Any] ?? [:]
        return .init(item: d["item"] as? String, bytes: d["bytes"] as? Int ?? 0, queuedMs: d["queuedMs"] as? Int ?? 0)
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
        Self.append(entry, to: Self.viewportLog)
    }

    /// The phone's connection coming and going, one JSON line per event, in
    /// phone-connection.log next to agent.md: why a connection ended (on both
    /// sides), how long the phone was away, and whether a reply was being
    /// played, so cut-off replies on a bad network can be diagnosed.
    static var connectionLog: URL { Paths.root.appendingPathComponent("phone-connection.log") }
    /// Past this size the log starts over (the old one is kept as .old).
    static let connectionLogLimit = 2_000_000

    private func log(_ event: String, _ fields: [String: Any] = [:]) {
        var entry = fields
        entry["event"] = event
        entry["time"] = ISO8601DateFormatter().string(from: Date())
        entry["device"] = device
        entry["phase"] = session.phase.label
        entry["conversing"] = session.conversationActive
        let url = Self.connectionLog
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.connectionLogLimit {
            let old = url.appendingPathExtension("old")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        Self.append(entry, to: url)
    }

    private static func append(_ entry: [String: Any], to url: URL) {
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// What the page did, as it reports it ("diag"): the tap, the start sound,
    /// the microphone (which one), the page hidden. It may report late (kept
    /// while offline), so `at` is when it happened, from how long ago it says.
    private func logPage(_ report: [String: Any]) {
        var entry = report
        entry["type"] = nil
        entry["agoMs"] = nil
        let ago = Double(report["agoMs"] as? Int ?? 0) / 1000
        entry["at"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-ago))
        log("page", entry)
    }

    /// Seconds of reply audio (24 kHz, 16-bit) sent to the page in the last 10 s.
    private func recentReplySeconds() -> Double {
        let since = Date().addingTimeInterval(-10)
        recentAudio.removeAll { $0.0 < since }
        return Self.round(Double(recentAudio.reduce(0) { $0 + $1.1 }) / 48_000)
    }

    private static func round(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    private func command(_ type: String) {
        switch type {
        case "conversation_start":
            micReceived = 0  // the page counts from the start of each conversation too
            session.startConversation()
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
