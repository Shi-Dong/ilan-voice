import AppKit
import Foundation

/// Keeps the app in step with the `main` branch on GitHub.
///
/// Each build stamps its git commit into Info.plist (`IlanVoiceCommit`). To
/// check, the updater asks GitHub for the newest commit on `main`. To install,
/// it pulls the source into Application Support, builds it with the same
/// `scripts/build-app.sh` a person would run, swaps the new app in after this
/// one quits, and reopens it. Building on the Mac itself means there is no
/// downloaded app for Gatekeeper to quarantine; the only requirement is the
/// Xcode Command Line Tools.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(commit: String, summary: String, date: Date?)
        case installing(String)
        case failed(String)
    }

    static let repo = "Shi-Dong/ilan-voice"
    static let branch = "main"

    @Published private(set) var state: State = .idle

    static var sourceDir: URL { Paths.root.appendingPathComponent("source", isDirectory: true) }
    static var logFile: URL { Paths.root.appendingPathComponent("update.log") }

    /// The commit this copy was built from, or nil for builds made before the stamp existed.
    var currentCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "IlanVoiceCommit") as? String
    }

    var currentDescription: String {
        guard let sha = currentCommit, !sha.isEmpty else { return "unknown build" }
        let built = Bundle.main.object(forInfoDictionaryKey: "IlanVoiceBuildDate") as? String
        return String(sha.prefix(7)) + (built.map { " · built \($0)" } ?? "")
    }

    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    var isBusy: Bool {
        switch state {
        case .checking, .installing: true
        default: false
        }
    }

    // MARK: Check

    func check() async {
        guard !isBusy else { return }
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/commits/\(Self.branch)")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = obj["sha"] as? String else {
                state = .failed("GitHub did not return the latest commit.")
                return
            }
            if sha == currentCommit {
                state = .upToDate
                return
            }
            let commit = obj["commit"] as? [String: Any]
            let message = (commit?["message"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            let dateString = (commit?["committer"] as? [String: Any])?["date"] as? String
            state = .available(commit: sha, summary: message, date: dateString.flatMap { ISO8601DateFormatter().date(from: $0) })
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Install

    func install() async {
        guard !isBusy else { return }
        guard Self.hasCommandLineTools() else {
            state = .failed("Updating builds the app from source and needs Apple's Command Line Tools. Run `xcode-select --install` in Terminal, then try again.")
            return
        }
        state = .installing("Downloading the latest source…")
        let script = """
        set -euo pipefail
        SRC="$1"
        if [ -d "$SRC/.git" ]; then
            git -C "$SRC" fetch --quiet origin \(Self.branch)
            git -C "$SRC" reset --quiet --hard origin/\(Self.branch)
        else
            rm -rf "$SRC"
            git clone --quiet --branch \(Self.branch) https://github.com/\(Self.repo).git "$SRC"
        fi
        echo "@@BUILD"
        cd "$SRC"
        scripts/build-app.sh
        """
        let ok = await run(script: script, args: [Self.sourceDir.path])
        guard ok else { return }

        let newApp = Self.sourceDir.appendingPathComponent("dist/Ilan Voice.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            state = .failed("The build finished but produced no app. See update.log.")
            return
        }
        state = .installing("Restarting…")
        relaunch(replacingWith: newApp)
    }

    /// Runs a bash script, logging to update.log and turning milestones into status text.
    private func run(script: String, args: [String]) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "ilan-voice-update"] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = env
        FileManager.default.createFile(atPath: Self.logFile.path, contents: nil)
        let log = try? FileHandle(forWritingTo: Self.logFile)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            try? log?.write(contentsOf: data)
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                if text.contains("@@BUILD") { self?.state = .installing("Building — this takes a minute or two…") }
            }
        }
        let status: Int32 = await withCheckedContinuation { cont in
            process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { cont.resume(returning: -1) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        try? log?.close()
        if status != 0 {
            let tail = (try? String(contentsOf: Self.logFile, encoding: .utf8))?
                .split(separator: "\n").suffix(3).joined(separator: "\n") ?? ""
            state = .failed("Update failed (exit \(status)). \(tail)")
            return false
        }
        return true
    }

    /// A detached shell waits for this process to exit, swaps the bundle and reopens it.
    private func relaunch(replacingWith newApp: URL) {
        let target = Bundle.main.bundleURL
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2"
        cp -R "$3" "$2"
        open "$2"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "relaunch", String(ProcessInfo.processInfo.processIdentifier), target.path, newApp.path]
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Could not restart: \(error.localizedDescription)")
        }
    }

    private static func hasCommandLineTools() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
