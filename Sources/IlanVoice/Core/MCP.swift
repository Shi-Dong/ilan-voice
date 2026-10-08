import Foundation

enum MCPError: LocalizedError {
    case http(Int, String)
    case rpc(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): "HTTP \(code): \(body.prefix(200))"
        case .rpc(let msg): msg
        case .protocolError(let msg): msg
        }
    }
}

protocol MCPTransport: AnyObject {
    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any]
    func notify(_ method: String, _ params: [String: Any]) async throws
    func close()
}

private func rpcResult(_ msg: [String: Any]) throws -> [String: Any] {
    if let err = msg["error"] as? [String: Any] {
        throw MCPError.rpc(err["message"] as? String ?? "MCP error")
    }
    return msg["result"] as? [String: Any] ?? [:]
}

/// Streamable HTTP transport (the one Claude Code calls `"type": "http"`).
final class HTTPTransport: MCPTransport {
    private let url: URL
    private let headers: [String: String]
    private var sessionID: String?
    private var nextID = 1

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    private func post(_ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MCPError.protocolError("Not an HTTP response") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let (data, resp) = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let contentType = resp.value(forHTTPHeaderField: "Content-Type") ?? ""
        var messages: [[String: Any]] = []
        if contentType.contains("text/event-stream") {
            let text = String(data: data, encoding: .utf8) ?? ""
            for event in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
                let payload = event.split(separator: "\n")
                    .filter { $0.hasPrefix("data:") }
                    .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n")
                if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                    messages.append(obj)
                }
            }
        } else if let obj = try? JSONSerialization.jsonObject(with: data) {
            messages = (obj as? [[String: Any]]) ?? [(obj as? [String: Any]) ?? [:]]
        }
        guard let msg = messages.first(where: { ($0["id"] as? NSNumber)?.intValue == id }) else {
            throw MCPError.protocolError("No reply to \(method)")
        }
        return try rpcResult(msg)
    }

    func notify(_ method: String, _ params: [String: Any]) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func close() {}
}

/// stdio transport: newline-delimited JSON-RPC to a child process.
final class StdioTransport: MCPTransport {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1

    init(command: String, args: [String], env: [String: String]) throws {
        var environment = ProcessInfo.processInfo.environment
        // Apps launched from Finder get a bare PATH; add the usual tool dirs.
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.cargo/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        environment.merge(env) { _, new in new }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in self?.failAll("MCP server exited") }
        try process.run()
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (msg["id"] as? NSNumber)?.intValue else { continue }
            lock.lock()
            let cont = pending.removeValue(forKey: id)
            lock.unlock()
            if let cont {
                do { cont.resume(returning: try rpcResult(msg)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func failAll(_ reason: String) {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        all.values.forEach { $0.resume(throwing: MCPError.protocolError(reason)) }
    }

    private func write(_ obj: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending[id] = cont
            lock.unlock()
            do {
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            } catch {
                lock.lock()
                let c = pending.removeValue(forKey: id)
                lock.unlock()
                c?.resume(throwing: error)
            }
        }
    }

    func notify(_ method: String, _ params: [String: Any]) async throws {
        try write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    func close() {
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}

/// One tool, exposed to the model as a Realtime "function".
struct ToolBinding: Identifiable {
    var id: String { functionName }
    let functionName: String
    let server: String
    let toolName: String
    let description: String
    let schema: [String: Any]
}

/// One server from `mcp.json`, in Swift-native values a connect task can hold.
struct ServerSpec: Sendable {
    let url: String?
    let headers: [String: String]
    let command: String?
    let args: [String]
    let env: [String: String]
}

struct ServerStatus: Identifiable {
    var id: String { name }
    let name: String
    var state: String
    var toolCount: Int
    var ok: Bool
}

/// Loads `mcp.json`, connects to every server, and runs tool calls.
@MainActor
final class MCPManager: ObservableObject {
    @Published private(set) var servers: [ServerStatus] = []
    @Published private(set) var tools: [ToolBinding] = []
    @Published private(set) var loading = false

    private var transports: [String: MCPTransport] = [:]
    private static let maxOutput = 24_000

    func reload() async {
        loading = true
        defer { loading = false }
        transports.values.forEach { $0.close() }
        transports.removeAll()
        tools.removeAll()

        guard let config = Self.readConfig() else {
            servers = []
            return
        }
        servers = config.keys.sorted().map { ServerStatus(name: $0, state: "Connecting…", toolCount: 0, ok: false) }

        // Sequential on purpose. Connecting in a task group ran several
        // `connect` calls at once, and their JSON-RPC replies are bridged
        // `NSDictionary`s: casting them to `[String: Any]` from two threads at
        // the same time crashed the app in the runtime's bridging code (an
        // EXC_BAD_ACCESS under `swift_dynamicCast`). Servers answer in a few
        // hundred milliseconds each, so doing them in turn is cheap and safe.
        for name in config.keys.sorted() {
            guard let spec = config[name],
                  let i = servers.firstIndex(where: { $0.name == name }) else { continue }
            do {
                let (transport, found) = try await Self.connect(name: name, spec: spec)
                transports[name] = transport
                tools.append(contentsOf: found)
                servers[i] = ServerStatus(name: name, state: "\(found.count) tools", toolCount: found.count, ok: true)
            } catch {
                servers[i] = ServerStatus(name: name, state: error.localizedDescription, toolCount: 0, ok: false)
            }
        }

        tools.sort { $0.functionName < $1.functionName }
    }

    /// Reads every server up front into Swift-native values. The casts have to
    /// happen here, on one thread: `JSONSerialization` hands back lazily bridged
    /// `NSDictionary`s, and bridging the same one from several connect tasks at
    /// once crashed the app inside the runtime's dictionary bridge.
    static func readConfig() -> [String: ServerSpec]? {
        guard let data = try? Data(contentsOf: Paths.mcpFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: [String: Any]] else { return nil }
        return servers.compactMapValues { spec in
            guard (spec["disabled"] as? Bool) != true else { return nil }
            return ServerSpec(
                url: spec["url"] as? String,
                headers: spec["headers"] as? [String: String] ?? [:],
                command: spec["command"] as? String,
                args: spec["args"] as? [String] ?? [],
                env: spec["env"] as? [String: String] ?? [:])
        }
    }

    private static func connect(name: String, spec: ServerSpec) async throws -> (MCPTransport, [ToolBinding]) {
        let transport: MCPTransport
        // "${NAME}" anywhere in a server's settings is filled from the secret store.
        let expand = SecretStore.expand
        if let urlString = spec.url.map(expand), let url = URL(string: urlString) {
            transport = HTTPTransport(url: url, headers: spec.headers.mapValues(expand))
        } else if let command = spec.command.map(expand) {
            transport = try StdioTransport(command: command, args: spec.args.map(expand),
                                           env: spec.env.mapValues(expand))
        } else {
            throw MCPError.protocolError("Needs a \"url\" or a \"command\"")
        }
        _ = try await transport.request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "Ilan Voice", "version": "1.0"],
        ])
        try await transport.notify("notifications/initialized", [:])

        var bindings: [ToolBinding] = []
        var cursor: String?
        repeat {
            let result = try await transport.request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            for tool in result["tools"] as? [[String: Any]] ?? [] {
                guard let toolName = tool["name"] as? String else { continue }
                var schema = tool["inputSchema"] as? [String: Any] ?? [:]
                if schema["type"] == nil { schema["type"] = "object" }
                if schema["properties"] == nil { schema["properties"] = [String: Any]() }
                bindings.append(ToolBinding(
                    functionName: functionName(server: name, tool: toolName),
                    server: name, toolName: toolName,
                    description: String((tool["description"] as? String ?? "").prefix(1024)),
                    schema: schema))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil
        return (transport, bindings)
    }

    /// Realtime function names must match ^[a-zA-Z0-9_-]{1,64}$.
    static func functionName(server: String, tool: String) -> String {
        let raw = "\(server)__\(tool)"
        let cleaned = String(raw.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" ? Character($0) : "_"
        })
        return String(cleaned.prefix(64))
    }

    var realtimeTools: [[String: Any]] {
        tools.map { ["type": "function", "name": $0.functionName, "description": $0.description, "parameters": $0.schema] }
    }

    /// Runs one tool call. Errors come back as text so the model can explain them.
    func call(functionName: String, arguments: String) async -> String {
        guard let binding = tools.first(where: { $0.functionName == functionName }),
              let transport = transports[binding.server] else {
            return "Error: unknown tool \(functionName)"
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        do {
            let result = try await transport.request("tools/call", ["name": binding.toolName, "arguments": args])
            var parts: [String] = []
            for item in result["content"] as? [[String: Any]] ?? [] {
                switch item["type"] as? String {
                case "text": parts.append(item["text"] as? String ?? "")
                case "resource":
                    let res = item["resource"] as? [String: Any]
                    parts.append(res?["text"] as? String ?? "[resource \(res?["uri"] as? String ?? "")]")
                case let other: parts.append("[\(other ?? "unknown") content omitted]")
                }
            }
            if parts.isEmpty, let structured = result["structuredContent"],
               let data = try? JSONSerialization.data(withJSONObject: structured) {
                parts.append(String(data: data, encoding: .utf8) ?? "")
            }
            var text = parts.joined(separator: "\n")
            if (result["isError"] as? Bool) == true { text = "Tool error: " + text }
            if text.count > Self.maxOutput { text = String(text.prefix(Self.maxOutput)) + "\n…[truncated]" }
            return text.isEmpty ? "(no output)" : text
        } catch {
            return "Error calling \(binding.toolName): \(error.localizedDescription)"
        }
    }

    /// Copies the MCP servers from Claude Code's `~/.claude.json`.
    static func importFromClaudeCode() throws -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else {
            throw MCPError.protocolError("No mcpServers in ~/.claude.json")
        }
        var merged = (try? JSONSerialization.jsonObject(with: Data(contentsOf: Paths.mcpFile)) as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]
        merged.merge(servers) { _, new in new }
        let out = try JSONSerialization.data(withJSONObject: ["mcpServers": merged], options: [.prettyPrinted, .sortedKeys])
        try out.write(to: Paths.mcpFile, options: .atomic)
        return servers.count
    }
}
