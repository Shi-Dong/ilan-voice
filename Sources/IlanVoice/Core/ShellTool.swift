import AppKit
import Foundation

/// The built-in `run_shell` tool: lets the model run a bash command on this
/// Mac. Off by default. Every command needs the user's OK on screen unless it
/// matches the allow-list and contains no shell operators.
enum ShellTool {
    static let functionName = "run_shell"
    static let maxOutput = 24_000

    static var definition: [String: Any] {
        [
            "type": "function",
            "name": functionName,
            "description": """
            Run a bash command on the user's Mac and get back its exit code and \
            combined stdout/stderr. The user must approve most commands on screen, \
            so briefly say what you are about to run before calling this. Prefer \
            short, read-only commands; never run destructive commands unless the \
            user explicitly asked for exactly that. Long-running commands are \
            stopped after the timeout.
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The bash command to run."],
                    "working_directory": ["type": "string",
                                          "description": "Optional directory to run in; defaults to the one set in Settings."],
                ],
                "required": ["command"],
            ] as [String: Any],
        ]
    }

    /// True when the command may run without asking: it starts with an
    /// allow-listed prefix (whole words) and has no operators that could chain
    /// or redirect into something else.
    static func isAllowListed(_ command: String, allowList: [String]) -> Bool {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let operators = [";", "&", "|", ">", "<", "`", "$(", "\n", "\r"]
        guard !cmd.isEmpty, !operators.contains(where: { cmd.contains($0) }) else { return false }
        return allowList.contains { entry in
            let prefix = entry.trimmingCharacters(in: .whitespaces)
            guard !prefix.isEmpty else { return false }
            return cmd == prefix || cmd.hasPrefix(prefix + " ")
        }
    }

    /// Runs `command` with `bash -lc`, merging stdout and stderr. Kills it
    /// after `timeout` seconds.
    static func run(_ command: String, in directory: String, timeout: TimeInterval) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        var isDir: ObjCBool = false
        let dir = (directory as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return "Error: working directory does not exist: \(dir)"
        }
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["TERM"] = "dumb"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data) }
        }

        let started = Date()
        let status: Int32 = await withCheckedContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                collector.append(Data("Could not start bash: \(error.localizedDescription)".utf8))
                cont.resume(returning: -1)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                collector.timedOut = true
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { collector.append(rest) }

        var output = String(decoding: collector.data, as: UTF8.self)
        if output.count > maxOutput {
            output = String(output.prefix(maxOutput)) + "\n…[output truncated]"
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        var header = collector.timedOut
            ? "Stopped after the \(Int(timeout)) s timeout."
            : "Exit code \(status) (\(seconds) s)."
        header += " Directory: \(dir)"
        return header + "\n" + (output.isEmpty ? "(no output)" : output)
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        var timedOut = false

        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }

        func append(_ chunk: Data) {
            lock.lock()
            buffer.append(chunk)
            lock.unlock()
        }
    }
}

/// Queue of commands waiting for the user's Run / Deny. The chat view shows
/// the first one as a card; the caller awaits the answer.
@MainActor
final class ShellApprovals: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let command: String
        let directory: String
        fileprivate let reply: (Bool) -> Void
    }

    @Published private(set) var queue: [Request] = []
    /// Unanswered requests are denied after this long.
    static let patience: TimeInterval = 120

    var current: Request? { queue.first }

    func ask(command: String, directory: String) async -> Bool {
        await withCheckedContinuation { cont in
            var answered = false
            let request = Request(command: command, directory: directory) { approved in
                guard !answered else { return }
                answered = true
                cont.resume(returning: approved)
            }
            queue.append(request)
            NSSound(named: "Submarine")?.play()
            NSApp.requestUserAttention(.criticalRequest)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience) { [weak self] in
                self?.answer(request.id, approved: false)
            }
        }
    }

    func answer(_ id: UUID, approved: Bool) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let request = queue.remove(at: index)
        request.reply(approved)
    }

    /// Denies everything still waiting (e.g. when the conversation changes).
    func denyAll() {
        for request in queue { request.reply(false) }
        queue.removeAll()
    }
}
