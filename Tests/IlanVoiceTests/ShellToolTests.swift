@testable import IlanVoice

/// The allow-list is the only thing between the model and the user's shell,
/// so every rule in `ShellTool.refusal` gets a test.
func registerShellToolTests() {
    let defaults = ShellTool.defaultAllowList.split(separator: "\n").map(String.init)

    suite("ShellTool") { test in
        test("allows read-only commands") {
            for command in ["ls", "ls -la ~/Desktop", "git status", "git log -3 --oneline", "cat a.txt | grep foo | wc -l",
                            "cd /tmp && ls", "pwd; whoami", "ls 2>/dev/null", "grep x f 2>&1 | head"] {
                expect(ShellTool.refusal(for: command, allowList: defaults) == nil, command)
            }
        }
        test("refuses commands not on the list") {
            let reason = ShellTool.refusal(for: "rm -rf ~/x", allowList: defaults)
            expect(reason?.contains("`rm -rf` is not on the allow-list") == true, reason ?? "nil")
        }
        test("prefixes match whole words only") {
            expect(ShellTool.matches("ls -l", entry: "ls"))
            expect(ShellTool.matches("ls", entry: "ls"))
            expect(!ShellTool.matches("lsblk", entry: "ls"))
            expect(ShellTool.refusal(for: "lsof -i", allowList: ["ls"]) != nil)
        }
        test("every part of a pipeline must be allowed") {
            for command in ["cat f | rm g", "ls && curl x.com", "ls || shutdown"] {
                expect(ShellTool.refusal(for: command, allowList: defaults) != nil, command)
            }
        }
        test("refuses writing, substitution and background jobs") {
            for command in ["echo hi > f.txt", "cat a >> b", "ls `rm x`", "echo $(rm x)", "diff <(ls) <(ls)", "sleep 1 & ls"] {
                expect(ShellTool.refusal(for: command, allowList: defaults + ["sleep"]) != nil, command)
            }
        }
        test("refuses writing flags even when the command is allowed") {
            for command in ["find . -delete", "find . -name x -exec rm {} ;", "git branch -D old",
                            "sort -o out.txt in.txt", "sysctl -w a=1"] {
                expect(ShellTool.refusal(for: command, allowList: defaults) != nil, command)
            }
        }
        test("empty command is refused") {
            expectEqual(ShellTool.refusal(for: "   ", allowList: defaults), "the command is empty")
        }
        test("regex entries match the whole part") {
            let list = ["/kubectl -n [a-z-]+ get .*/"]
            expect(ShellTool.refusal(for: "kubectl -n shi-dev get pods", allowList: list) == nil)
            expect(ShellTool.refusal(for: "kubectl -n shi-dev delete pods", allowList: list) != nil)
            expect(ShellTool.refusal(for: "x kubectl -n a get pods", allowList: list) != nil)
        }
        test("invalid regex entries are reported") {
            expectEqual(ShellTool.invalidRegexEntries(["ls", "/[a-/", "/ok.*/"]), ["/[a-/"])
            expect(!ShellTool.isRegexEntry("/"))
        }
        test("tool description follows bypass") {
            let normal = ShellTool.definition(bypass: false)["description"] as? String ?? ""
            let bypass = ShellTool.definition(bypass: true)["description"] as? String ?? ""
            expect(normal.contains("allow-list"))
            expect(bypass.contains("Run any bash command"))
            expect(!bypass.contains("Only commands on the user's allow-list"))
        }
    }
}
