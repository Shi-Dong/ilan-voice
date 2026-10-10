import Combine
import Foundation

/// One iPhone: its voice session, its conversation and its live connection.
/// Phones are told apart by a random device ID the web page keeps, so each
/// one talks in its own conversation and they can be used at the same time.
@MainActor
final class PhoneClient {
    let device: String
    let session: VoiceSession
    var onConnectionChange: (() -> Void)?
    var isConnected: Bool { peer != nil }

    private let store: ConversationStore
    private let input = RemoteMicrophone()
    private let output = RemoteSpeaker()
    private var peer: WebSocketPeer?
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

        output.sendAudio = { [weak self] pcm in self?.peer?.send(binary: pcm) }
        output.sendStop = { [weak self] in self?.peer?.send(json: ["type": "audio_stop"]) }
        session.$phase.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sendState() } }
            .store(in: &cancellables)
        session.$errorMessage.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sendState() } }
            .store(in: &cancellables)
        store.$conversations
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendMessages() }
            .store(in: &cancellables)
    }

    /// A newer page for the same phone takes over; the old one is told so and
    /// does not reconnect on its own (otherwise the two would keep swapping).
    func attach(_ newPeer: WebSocketPeer) {
        if let old = peer, old !== newPeer {
            old.send(json: ["type": "replaced"])
            old.close()
        }
        peer = newPeer
        newPeer.onBinary = { [weak self, weak newPeer] data in
            guard let self, newPeer === self.peer else { return }
            self.input.deliver(data)
        }
        newPeer.onText = { [weak self, weak newPeer] text in
            guard let self, newPeer === self.peer,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let type = obj["type"] as? String else { return }
            self.command(type)
        }
        newPeer.onClose = { [weak self, weak newPeer] in
            guard let self, newPeer === self.peer else { return }
            self.peer = nil
            if self.session.phase == .recording { self.session.releaseToTalk() }
            self.onConnectionChange?()
        }
        lastSentMessages = []
        newPeer.send(json: ["type": "hello_ok"])
        sendMessages(force: true)
        sendState()
        onConnectionChange?()
    }

    func disconnect() { peer?.close() }

    func shutDown() {
        peer?.close()
        peer = nil
        session.disconnect()
    }

    private func command(_ type: String) {
        switch type {
        case "press": session.pressToTalk()
        case "release": session.releaseToTalk()
        case "stop": session.interrupt()
        case "replay": replayLast()
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
        var state: [String: Any] = ["type": "state", "phase": session.phase.label,
                                    "busy": session.phase != .ready && session.phase != .offline]
        if let error = session.errorMessage { state["error"] = error }
        peer.send(json: state)
    }

    private func sendMessages(force: Bool = false) {
        guard let peer else { return }
        let conv = conversation(create: false).flatMap { id in store.conversations.first { $0.id == id } }
        let items: [[String: Any]] = (conv?.messages ?? []).suffix(80).map { m in
            switch m.role {
            case .user, .assistant:
                return ["id": m.id, "role": m.role == .user ? "user" : "assistant", "text": m.text, "pending": m.pending]
            case .tool:
                return ["id": m.id, "role": "tool", "text": m.toolName ?? "tool", "pending": m.pending]
            }
        }
        guard force || !NSArray(array: items).isEqual(to: lastSentMessages) else { return }
        lastSentMessages = items
        peer.send(json: ["type": "messages", "title": conv?.title ?? "Ilan Voice", "items": items])
    }
}
