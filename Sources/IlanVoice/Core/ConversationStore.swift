import Foundation

struct Message: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant, tool }

    var id: String
    var role: Role
    var text: String
    var createdAt = Date()
    /// File name under the conversation's `audio/` folder.
    var audioFile: String?
    var audioSeconds: Double?
    /// Still streaming (transcribing, speaking or running a tool).
    var pending = false
    /// For cached replies: has the user played it yet?
    var listened = true
    var toolName: String?
    var toolArguments: String?
}

struct Conversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "New conversation"
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [Message] = []

    var unheardCount: Int { messages.filter { !$0.listened }.count }
}

/// Owns every conversation on disk. Each change is written back (debounced),
/// so the transcript is never lost, whatever the output mode.
@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published var selectedID: UUID?

    private var pendingSaves: [UUID: DispatchWorkItem] = [:]
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init() {
        load()
        if conversations.isEmpty { _ = newConversation() }
        selectedID = conversations.first?.id
    }

    var selected: Conversation? { conversations.first { $0.id == selectedID } }

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.conversations, includingPropertiesForKeys: nil)) ?? []
        conversations = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("conversation.json")) else { return nil }
            return try? decoder.decode(Conversation.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func newConversation() -> Conversation {
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            selectedID = empty.id
            return empty
        }
        let conv = Conversation()
        conversations.insert(conv, at: 0)
        selectedID = conv.id
        saveNow(conv)
        return conv
    }

    func update(_ id: UUID, _ mutate: (inout Conversation) -> Void) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&conversations[idx])
        conversations[idx].updatedAt = Date()
        if conversations[idx].title == "New conversation",
           let first = conversations[idx].messages.first(where: { $0.role == .user && !$0.pending && !$0.text.isEmpty }) {
            conversations[idx].title = Self.title(from: first.text)
        }
        scheduleSave(conversations[idx].id)
    }

    func updateMessage(_ convID: UUID, _ msgID: String, _ mutate: (inout Message) -> Void) {
        update(convID) { conv in
            guard let i = conv.messages.firstIndex(where: { $0.id == msgID }) else { return }
            mutate(&conv.messages[i])
        }
    }

    func message(_ convID: UUID, _ msgID: String) -> Message? {
        conversations.first { $0.id == convID }?.messages.first { $0.id == msgID }
    }

    func rename(_ id: UUID, to title: String) {
        update(id) { $0.title = title.isEmpty ? "Untitled" : title }
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Paths.conversation(id))
        if selectedID == id { selectedID = conversations.first?.id }
        if conversations.isEmpty { newConversation() }
    }

    func audioURL(_ convID: UUID, _ file: String) -> URL {
        Paths.audioDir(convID).appendingPathComponent(file)
    }

    private func scheduleSave(_ id: UUID) {
        pendingSaves[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let conv = self.conversations.first(where: { $0.id == id }) else { return }
            self.saveNow(conv)
        }
        pendingSaves[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func flush() {
        for (id, work) in pendingSaves {
            work.cancel()
            if let conv = conversations.first(where: { $0.id == id }) { saveNow(conv) }
        }
        pendingSaves.removeAll()
    }

    private func saveNow(_ conv: Conversation) {
        let dir = Paths.conversation(conv.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? encoder.encode(conv) {
            try? data.write(to: dir.appendingPathComponent("conversation.json"), options: .atomic)
        }
        try? Self.markdown(conv).write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
    }

    static func markdown(_ conv: Conversation) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        var out = "# \(conv.title)\n\nStarted \(df.string(from: conv.createdAt))\n"
        for m in conv.messages {
            let time = df.string(from: m.createdAt)
            switch m.role {
            case .user:
                out += "\n## You · \(time)\n\n\(m.text)\n"
            case .assistant:
                out += "\n## Ilan · \(time)\n\n\(m.text)\n"
            case .tool:
                out += "\n> Tool `\(m.toolName ?? "?")` · \(time)\n>\n> Arguments: `\(m.toolArguments ?? "{}")`\n>\n"
                out += m.text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n"
            }
            if let audio = m.audioFile { out += "\n[audio](audio/\(audio))\n" }
        }
        return out
    }

    static func title(from text: String) -> String {
        let words = text.split(separator: " ").prefix(8).joined(separator: " ")
        return words.count < text.count ? words + "…" : words
    }
}
