import Foundation

/// One long-lived bash process. Commands run in it one after another, so
/// `cd`, `export` and activated environments carry over between them.
///
/// Each command is sent base64-encoded and run with `eval` inside the shell,
/// so a typo is reported as an error instead of killing the shell, and it
/// reads from /dev/null so nothing can swallow the next command. After the
/// command, the shell prints a unique marker line with the exit code and the
/// current directory; everything before that line is the output.
final class PersistentShell: @unchecked Sendable {
    struct Result {
        var output: String
        var exitCode: Int32?
        var directory: String?
        var timedOut = false
        var shellEnded = false
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var pending: (marker: String, continuation: CheckedContinuation<Result, Never>)?
    /// Called once, on any thread, when the bash process ends.
    var onExit: (() -> Void)?

    var isRunning: Bool { process.isRunning }

    init(directory: String) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--login", "-s"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["TERM"] = "dumb"
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.consume(data)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.output.fileHandleForReading.readabilityHandler = nil
            self.finishPending(shellEnded: true)
            self.onExit?()
        }
        try process.run()
    }

    /// Runs one command; at most `timeout` seconds before its child processes
    /// are stopped. If the shell itself is stuck too, the shell is ended.
    func run(_ command: String, timeout: TimeInterval) async -> Result {
        let marker = "__ILAN_DONE_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let encoded = Data(command.utf8).base64EncodedString()
        let script = """
        { eval "$(printf %s '\(encoded)' | /usr/bin/base64 -D)"; } </dev/null 2>&1
        __ilan_status=$?; printf '\\n%s %d %s\\n' '\(marker)' "$__ilan_status" "$PWD"

        """
        return await withCheckedContinuation { cont in
            lock.lock()
            buffer.removeAll()
            pending = (marker, cont)
            lock.unlock()
            do {
                try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            } catch {
                finishPending(shellEnded: true)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.handleTimeout(marker: marker)
            }
        }
    }

    /// Ends the shell and everything it started.
    func close() {
        guard process.isRunning else { return }
        killChildren()
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
    }

    // MARK: Internals

    private var timedOutMarker: String?

    private func handleTimeout(marker: String) {
        lock.lock()
        let stillWaiting = pending?.marker == marker
        if stillWaiting { timedOutMarker = marker }
        lock.unlock()
        guard stillWaiting else { return }
        // Stop the command; the shell then prints its marker and lives on.
        killChildren()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stuck = self.pending?.marker == marker
            self.lock.unlock()
            if stuck { self.close() }  // a builtin loop: nothing else will stop it
        }
    }

    private func killChildren() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        guard let (marker, cont) = pending,
              let text = String(data: buffer, encoding: .utf8),
              let markerRange = text.range(of: "\n" + marker + " "),
              let lineEnd = text[markerRange.upperBound...].firstIndex(of: "\n") else {
            lock.unlock()
            return
        }
        let tail = text[markerRange.upperBound..<lineEnd]
        let fields = tail.split(separator: " ", maxSplits: 1)
        var result = Result(output: String(text[..<markerRange.lowerBound]))
        result.exitCode = fields.first.flatMap { Int32($0) }
        result.directory = fields.count > 1 ? String(fields[1]) : nil
        result.timedOut = timedOutMarker == marker
        pending = nil
        buffer.removeAll()
        lock.unlock()
        cont.resume(returning: result)
    }

    private func finishPending(shellEnded: Bool) {
        lock.lock()
        guard let (marker, cont) = pending else { lock.unlock(); return }
        let text = String(decoding: buffer, as: UTF8.self)
        pending = nil
        buffer.removeAll()
        let timedOut = timedOutMarker == marker
        lock.unlock()
        cont.resume(returning: Result(output: text, timedOut: timedOut, shellEnded: shellEnded))
    }
}

/// The persistent bash sessions, one per conversation. The sidebar watches
/// `openConversations` to mark conversations with a running shell.
@MainActor
final class ShellSessions: ObservableObject {
    static let shared = ShellSessions()

    @Published private(set) var openConversations: Set<UUID> = []
    private var shells: [UUID: PersistentShell] = [:]

    func isOpen(_ conversation: UUID) -> Bool { openConversations.contains(conversation) }

    /// Runs `command` in the conversation's shell, starting one in
    /// `directory` if there is none yet.
    func run(_ command: String, conversation: UUID, directory: String, timeout: TimeInterval) async -> String {
        let shell: PersistentShell
        var started = false
        if let existing = shells[conversation], existing.isRunning {
            shell = existing
        } else {
            let dir = (directory as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                return "Error: working directory does not exist: \(dir)"
            }
            do {
                shell = try PersistentShell(directory: dir)
            } catch {
                return "Error: could not start bash: \(error.localizedDescription)"
            }
            shell.onExit = { [weak self] in
                Task { @MainActor in self?.forget(conversation, shell) }
            }
            shells[conversation] = shell
            openConversations.insert(conversation)
            started = true
        }

        let began = Date()
        let result = await shell.run(command, timeout: timeout)
        var text = result.output.trimmingCharacters(in: .newlines)
        if text.count > ShellTool.maxOutput {
            text = String(text.prefix(ShellTool.maxOutput)) + "\n…[output truncated]"
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(began))
        var header: String
        if result.shellEnded {
            header = result.timedOut
                ? "Stopped after the \(Int(timeout)) s timeout; the bash session had to be closed (cd and variables are reset)."
                : "The bash session ended (cd and variables are reset)."
        } else if result.timedOut {
            header = "Stopped after the \(Int(timeout)) s timeout. Exit code \(result.exitCode.map(String.init) ?? "?")."
        } else {
            header = "Exit code \(result.exitCode.map(String.init) ?? "?") (\(seconds) s)."
        }
        if let dir = result.directory { header += " Directory: \(dir)" }
        if started { header = "Started a new bash session for this conversation. " + header }
        return header + "\n" + (text.isEmpty ? "(no output)" : text)
    }

    /// Closes the conversation's shell. Returns false if there was none.
    @discardableResult
    func close(_ conversation: UUID) -> Bool {
        guard let shell = shells.removeValue(forKey: conversation) else { return false }
        openConversations.remove(conversation)
        shell.close()
        return true
    }

    func closeAll() {
        for id in Array(shells.keys) { close(id) }
    }

    private func forget(_ conversation: UUID, _ shell: PersistentShell) {
        guard shells[conversation] === shell else { return }
        shells.removeValue(forKey: conversation)
        openConversations.remove(conversation)
    }
}
