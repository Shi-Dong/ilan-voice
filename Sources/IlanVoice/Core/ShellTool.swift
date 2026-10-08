import Foundation

/// The built-in `run_shell` tool: lets the model run bash commands on this
/// Mac. Off by default. There is never a prompt: a command runs only if every
/// part of it is on the user's allow-list (read-only commands by default);
/// anything else is refused and the model is told why.
enum ShellTool {
    static let functionName = "run_shell"
    static let maxOutput = 24_000
    static let closeFunctionName = "close_shell"

    static var closeDefinition: [String: Any] {
        [
            "type": "function",
            "name": closeFunctionName,
            "description": """
            Close this conversation's persistent bash session and stop anything \
            still running in it. The next run_shell starts a fresh session.
            """,
            "parameters": ["type": "object", "properties": [String: Any]()] as [String: Any],
        ]
    }

    /// With `bypass` (Settings → Shell → Bypass all permissions) any command
    /// runs, and the description says so.
    static func definition(bypass: Bool) -> [String: Any] {
        let rules = bypass
            ? """
            Run any bash command on the user's Mac and get back its exit code \
            and combined stdout/stderr. The user has turned off all command \
            checks, so commands can change files and system state: be careful, \
            and confirm with the user before anything destructive.
            """
            : """
            Run a read-only bash command on the user's Mac and get back its exit \
            code and combined stdout/stderr. Only commands on the user's allow-list \
            run; pipes, &&, || and ; are fine when every part is allowed. Output \
            redirection (>), command substitution ($( ) or backticks) and \
            background jobs are refused. If a command is refused, tell the user \
            which command they could add to the allow-list in Settings.
            """
        return [
            "type": "function",
            "name": functionName,
            "description": rules + " " + """
            Long-running commands are stopped after the timeout. Commands run in \
            one persistent bash session per conversation, so cd, exported \
            variables and activated environments carry over between calls. \
            Call close_shell when you no longer need the session.
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The bash command to run."],
                    "working_directory": ["type": "string",
                                          "description": "Optional directory to cd into first (this stays the session's directory). A new session starts in the directory set in Settings."],
                ],
                "required": ["command"],
            ] as [String: Any],
        ]
    }

    /// Default allow-list: commands that only read. One prefix per line;
    /// a prefix matches whole words, so `ls` does not match `lsof`.
    static let defaultAllowList = [
        "cd", "pwd", "ls", "tree", "cat", "head", "tail", "wc", "grep", "rg", "find", "file",
        "stat", "du", "df", "which", "whereis", "type", "echo", "date", "cal", "whoami", "id",
        "hostname", "uname", "uptime", "ps", "printenv", "sw_vers", "sysctl", "lsof", "netstat",
        "ifconfig", "diskutil list", "diskutil info", "jq", "sort", "uniq", "cut", "tr", "column",
        "diff", "cmp", "shasum", "md5", "basename", "dirname", "realpath", "readlink",
        "git status", "git log", "git diff", "git show", "git branch", "git remote -v",
        "git rev-parse", "git ls-files", "git blame", "git describe", "git config --get",
        "git config --list", "git stash list", "git worktree list",
        "kubectl get", "kubectl describe", "kubectl logs", "kubectl top", "kubectl config view",
        "kubectl config get-contexts", "kubectl config current-context",
        "gh pr view", "gh pr list", "gh pr diff", "gh pr checks", "gh run list", "gh run view",
        "brew list", "brew info", "docker ps", "docker images", "docker logs", "tmux ls",
    ].joined(separator: "\n")

    /// Flags that turn an otherwise read-only command into one that writes.
    /// Checked even when the user has allow-listed the command.
    private static let writingFlags: [String: [String]] = [
        "find": ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"],
        "git branch": ["-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy", "-f", "--force",
                       "-u", "--set-upstream-to", "--unset-upstream", "--edit-description"],
        "sort": ["-o", "--output"],
        "sysctl": ["-w"],
    ]

    /// Redirections that only throw output away, removed before checking.
    private static let harmlessRedirects = ["2>&1", "1>&2", "&>/dev/null", "2>/dev/null", "1>/dev/null", ">/dev/null",
                                            "&> /dev/null", "2> /dev/null", "> /dev/null"]

    /// An entry is either a command prefix (whole words: `git log` allows
    /// `git log -3` but `ls` does not allow `lsof`) or, when wrapped in slashes,
    /// a regular expression that must match the whole command part, e.g.
    /// `/kubectl -n [a-z-]+ get .*/`.
    static func matches(_ part: String, entry: String) -> Bool {
        if let regex = regex(from: entry) {
            return regex.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)) != nil
        }
        return part == entry || part.hasPrefix(entry + " ")
    }

    static func isRegexEntry(_ entry: String) -> Bool {
        entry.count >= 2 && entry.hasPrefix("/") && entry.hasSuffix("/")
    }

    /// The compiled pattern for a `/…/` entry, anchored to the whole part;
    /// nil for prefix entries and for patterns that don't compile.
    static func regex(from entry: String) -> NSRegularExpression? {
        guard isRegexEntry(entry) else { return nil }
        let pattern = String(entry.dropFirst().dropLast())
        return try? NSRegularExpression(pattern: "^(?:\(pattern))$")
    }

    /// `/…/` entries that are not valid regular expressions (they match nothing).
    static func invalidRegexEntries(_ allowList: [String]) -> [String] {
        allowList.filter { isRegexEntry($0) && regex(from: $0) == nil }
    }

    /// nil when every part of `command` is allowed; otherwise the reason it is refused.
    static func refusal(for command: String, allowList: [String]) -> String? {
        var cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return "the command is empty" }
        for redirect in harmlessRedirects { cmd = cmd.replacingOccurrences(of: redirect, with: " ") }
        if cmd.contains(">") { return "it redirects output into a file (>)" }
        if cmd.contains("`") || cmd.contains("$(") || cmd.contains("<(") { return "it uses command substitution" }
        // Split into the commands of a pipeline / list.
        let separators = ["&&", "||", ";", "|", "\n", "\r"]
        var parts = [cmd]
        for sep in separators { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.contains(where: { $0.contains("&") }) { return "it starts a background job (&)" }
        for part in parts {
            guard allowList.contains(where: { matches(part, entry: $0) }) else {
                return "`\(part.split(separator: " ").prefix(2).joined(separator: " "))` is not on the allow-list"
            }
            let words = Set(part.split(separator: " ").map(String.init))
            for (prefix, flags) in writingFlags where part == prefix || part.hasPrefix(prefix + " ") {
                if let flag = flags.first(where: { words.contains($0) || part.contains(" \($0)=") }) {
                    return "`\(prefix) \(flag)` can change files"
                }
            }
        }
        return nil
    }
}
