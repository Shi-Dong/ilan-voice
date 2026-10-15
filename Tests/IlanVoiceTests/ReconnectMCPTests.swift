import Foundation
@testable import IlanVoice

/// Reconnect restarts the MCP servers, so a server that changed is picked up.
@MainActor
func registerReconnectMCPTests() {
    /// A tiny stdio MCP server whose one tool is named by the file `toolFile`:
    /// changing that file stands in for changing the server.
    func fakeServer(toolFile: URL) -> URL {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("ilan-fake-mcp-\(UUID().uuidString).py")
        try? """
        import json, sys
        tool = open(\(String(reflecting: toolFile.path))).read().strip()
        for line in sys.stdin:
            msg = json.loads(line)
            if "id" not in msg: continue
            if msg["method"] == "initialize":
                result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
            elif msg["method"] == "tools/list":
                result = {"tools": [{"name": tool, "description": "A test tool", "inputSchema": {"type": "object"}}]}
            else:
                result = {}
            print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}), flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        return script
    }
    func blocking(_ body: @escaping () async -> Void) {
        var done = false
        Task { await body(); done = true }
        _ = waitFor(10) { done }
    }
    func toolNames(_ session: VoiceSession) -> [String] { session.builtInTools().compactMap { $0["name"] as? String } }

    suite("Reconnect and MCP servers") { test in
        test("Reconnect restarts the MCP servers: a changed server's tools replace the old ones") {
            let toolFile = FileManager.default.temporaryDirectory.appendingPathComponent("ilan-fake-tool-\(UUID().uuidString)")
            try? "alpha".write(to: toolFile, atomically: true, encoding: .utf8)
            let script = fakeServer(toolFile: toolFile)
            let config = #"{"mcpServers": {"fake": {"command": "python3", "args": [\#(String(reflecting: script.path))]}}}"#
            let hadConfig = try? Data(contentsOf: Paths.mcpFile)
            try? config.write(to: Paths.mcpFile, atomically: true, encoding: .utf8)
            defer {
                if let hadConfig { try? hadConfig.write(to: Paths.mcpFile) } else { try? FileManager.default.removeItem(at: Paths.mcpFile) }
                try? FileManager.default.removeItem(at: script)
                try? FileManager.default.removeItem(at: toolFile)
            }
            let store = ConversationStore()
            let conv = store.newConversation()
            let mcp = MCPManager()
            let session = VoiceSession(store: store, mcp: mcp, input: FakeMic(), output: FakeSpeaker(),
                                       isRemote: false, target: { conv.id })
            blocking { await mcp.reload() }  // what the app does at launch
            expect(toolNames(session).contains("fake__alpha"), "\(toolNames(session))")

            try? "beta".write(to: toolFile, atomically: true, encoding: .utf8)  // the server changed
            blocking { await session.reconnect() }
            expect(toolNames(session).contains("fake__beta"), "the changed server wasn't picked up: \(toolNames(session))")
            expect(!toolNames(session).contains("fake__alpha"), "the old tool is still offered")
            expectEqual(mcp.servers.map(\.ok), [true])
        }
    }
}
