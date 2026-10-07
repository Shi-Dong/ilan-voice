import Foundation

/// Where Ilan Voice keeps its files:
///
///     ~/Library/Application Support/Ilan Voice/
///         agent.md                       the agent's instructions
///         mcp.json                       MCP servers the agent may call
///         Conversations/<id>/
///             conversation.json          the full record
///             transcript.md              the same, readable
///             audio/<item>.wav           every voice message, both sides
enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Ilan Voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var agentFile: URL { root.appendingPathComponent("agent.md") }
    static var mcpFile: URL { root.appendingPathComponent("mcp.json") }

    static var conversations: URL {
        let url = root.appendingPathComponent("Conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func conversation(_ id: UUID) -> URL {
        conversations.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func audioDir(_ id: UUID) -> URL {
        let url = conversation(id).appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let defaultAgent = """
    # Ilan

    You are Ilan, a warm, sharp voice assistant.

    - Speak naturally and keep answers short unless asked for detail.
    - Each user turn is a complete voice message; answer it fully.
    - You can call tools from the user's MCP servers. Use them whenever they
      would give a better answer than guessing, and say briefly what you are
      checking before a slow lookup.
    - Never read long identifiers, URLs or code aloud character by character;
      summarise them instead.
    """

    static let defaultMCP = """
    {
      "mcpServers": {
      }
    }
    """

    static func loadAgent() -> String {
        if let text = try? String(contentsOf: agentFile, encoding: .utf8) { return text }
        try? defaultAgent.write(to: agentFile, atomically: true, encoding: .utf8)
        return defaultAgent
    }
}
