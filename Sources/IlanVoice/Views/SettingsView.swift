import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var mcp: MCPManager
    @ObservedObject var updater: Updater
    @ObservedObject var ptt: PushToTalk
    let phone: PhoneServer

    enum Tab: Hashable { case general, agent, mcp, shell, dictionary }

    /// Settings always opens on General. SwiftUI keeps the Settings window
    /// (and this view) alive after it is closed, so onAppear/onDisappear don't
    /// fire reliably. Instead the tab goes back to General whenever the window
    /// closes, and whenever any Settings button in the app is clicked (even if
    /// the window is already open behind another one).
    @Local private var tab: Tab = .general
    @Local private var window = WeakWindow()

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(updater: updater, ptt: ptt, phone: phone).tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            AgentSettings().tabItem { Label("Agent", systemImage: "person.text.rectangle") }.tag(Tab.agent)
            MCPSettings(mcp: mcp).tabItem { Label("MCP Tools", systemImage: "wrench.and.screwdriver") }.tag(Tab.mcp)
            ShellSettings().tabItem { Label("Shell", systemImage: "terminal") }.tag(Tab.shell)
            DictionarySettings().tabItem { Label("Dictionary", systemImage: "character.book.closed") }.tag(Tab.dictionary)
        }
        .background(WindowReader { window.value = $0 })
        .onAppear { tab = .general }
        .onReceive(NotificationCenter.default.publisher(for: .showGeneralSettings)) { _ in tab = .general }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let closing = note.object as? NSWindow, closing === window.value { tab = .general }
        }
        .frame(width: 640, height: 520)
        .preferredColorScheme(.dark)
        .tint(Theme.mint)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var updater: Updater
    @ObservedObject var ptt: PushToTalk
    let phone: PhoneServer
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            UpdatesSection(updater: updater)
            Section("OpenAI") {
                APIKeyRow(title: "API key", provider: .openAI, key: $settings.apiKey)
                TextField("Realtime model", text: $settings.model)
                Picker("Voice", selection: $settings.voiceGender) {
                    ForEach(VoiceGender.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Speaking speed") {
                    VStack(alignment: .trailing, spacing: 2) {
                        TickSlider(value: $settings.voiceSpeed, range: 0.5...1.5, step: 0.1)
                            .frame(width: 220)
                        HStack {
                            Text("Slower")
                            Spacer()
                            Text(String(format: "%.1f×", settings.voiceSpeed)).monospacedDigit()
                            Spacer()
                            Text("Faster")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 220)
                    }
                }
                Picker("Reasoning effort", selection: $settings.reasoningEffort) {
                    ForEach(AppSettings.reasoningEfforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                TextField("Transcription model", text: $settings.transcriptionModel)
                TextField("Title model", text: $settings.titleModel)
                    .help("Names each conversation (30 characters max) from its 10 latest messages after every reply.")
            }
            Section("Talking") {
                MicrophonePicker()
                TalkTriggerRecorder(ptt: ptt)
                TalkTriggerRecorder(ptt: ptt, target: .replay)
                Picker("Replies", selection: $settings.outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Real-time plays a reply as it is generated. Cached saves it and waits for you to press play (or ⇧⌘P). Transcripts and audio are always saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            WebSearchSection()
            PhoneSection(phone: phone)
            Section("App") {
                Toggle("Hide from Dock when the window is closed", isOn: $settings.hideDockWhenClosed)
                    .onChange(of: settings.hideDockWhenClosed) { _, hide in
                        if !hide { AppDelegate.showInDock() }
                    }
                Text("Ilan Voice keeps running in the menu bar, so the talk key still works. Choose Show Ilan Voice from the menu bar icon to bring the window and the Dock icon back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Folder") {
                    Button("Open in Finder") { NSWorkspace.shared.open(Paths.root) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// agent.md lives on disk and is edited in the user's own editor; this tab
/// just shows where it is and how to get to it.
private struct AgentSettings: View {
    @Local private var modified: Date?
    @Local private var lineCount = 0
    @Local private var confirmReset = false

    private var path: String { Paths.agentFile.path }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            VStack(spacing: 6) {
                Text("agent.md").font(.system(size: 20, weight: .semibold))
                Text("The instructions Ilan follows in every conversation.")
                    .foregroundStyle(.secondary)
            }
            FilePathPill(path: path)

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.agentFile])
                } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    NSWorkspace.shared.open(Paths.agentFile)
                } label: {
                    Label("Open in Editor", systemImage: "square.and.pencil")
                }
                .controlSize(.large)
            }

            if let modified {
                Text("Edited \(modified, format: .relative(presentation: .named)) · \(lineCount) lines")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Text("Changes apply to the next conversation (or Voice → Reconnect).")
                Spacer()
                Button("Reset to Default…") { confirmReset = true }
                    .buttonStyle(.link)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .confirmationDialog("Replace agent.md with the default instructions?", isPresented: $confirmReset) {
            Button("Replace", role: .destructive) {
                try? Paths.defaultAgent.write(to: Paths.agentFile, atomically: true, encoding: .utf8)
                refresh()
            }
        } message: {
            Text("Your current instructions will be overwritten.")
        }
    }

    private func refresh() {
        let text = Paths.loadAgent()  // creates the file with defaults if missing
        lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

/// mcp.json, like agent.md, is edited in the user's own editor; this tab
/// shows where it is, the servers it defines and whether each one connected.
private struct MCPSettings: View {
    @ObservedObject var mcp: MCPManager
    @Local private var modified: Date?
    @Local private var note: String?

    private var path: String { Paths.mcpFile.path }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            VStack(spacing: 6) {
                Text("mcp.json").font(.system(size: 20, weight: .semibold))
                Text("The MCP servers whose tools Ilan can use.")
                    .foregroundStyle(.secondary)
            }
            FilePathPill(path: path)

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.mcpFile])
                } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    NSWorkspace.shared.open(Paths.mcpFile)
                } label: {
                    Label("Open in Editor", systemImage: "square.and.pencil")
                }
                .controlSize(.large)
            }

            serverList

            Spacer(minLength: 0)
            HStack {
                Text(note ?? "Same format as Claude Code. Edits are picked up when you come back to Ilan Voice.")
                    .lineLimit(1)
                Spacer()
                Button("Import from Claude Code") {
                    do {
                        let n = try MCPManager.importFromClaudeCode()
                        note = "Imported \(n) servers."
                        reload()
                    } catch { note = error.localizedDescription }
                }
                .buttonStyle(.link)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { modified = Self.modificationDate() }
        // Reload after the file was edited elsewhere, e.g. in the editor.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let now = Self.modificationDate()
            if now != modified { reload() }
        }
    }

    /// One quiet row per server: a status dot, the name, and its tool count or error.
    private var serverList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Servers").font(.system(size: 12, weight: .semibold))
                if mcp.loading { ProgressView().controlSize(.mini) }
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(mcp.loading)
                    .help("Reload mcp.json and reconnect to every server")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if mcp.servers.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text("No servers yet. Add one to mcp.json, or import them from Claude Code.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
            ForEach(mcp.servers) { s in
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 8) {
                    Circle().fill(s.ok ? Theme.mint : Theme.orange).frame(width: 7, height: 7)
                    Text(s.name).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 12)
                    Text(s.state)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(s.state)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
        .frame(maxWidth: 520)
    }

    private func reload() {
        modified = Self.modificationDate()
        Task { await mcp.reload() }
    }

    private static func modificationDate() -> Date? {
        if !FileManager.default.fileExists(atPath: Paths.mcpFile.path) {
            try? Paths.defaultMCP.write(to: Paths.mcpFile, atomically: true, encoding: .utf8)
        }
        return (try? FileManager.default.attributesOfItem(atPath: Paths.mcpFile.path))?[.modificationDate] as? Date
    }
}

/// A file's path in a rounded pill, with a button that copies it.
private struct FilePathPill: View {
    let path: String
    @Local private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy path")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
        .frame(maxWidth: 520)
    }
}

private struct UpdatesSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Section("Updates") {
            LabeledContent("This version", value: updater.currentDescription)
            HStack(alignment: .top, spacing: 8) {
                status
                Spacer()
                if case .available = updater.state {
                    Button("Install Update") { Task { await updater.install() } }
                        .buttonStyle(.borderedProminent)
                } else if case .readyToRestart = updater.state {
                    Button("Restart Now") { updater.restartNow() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Check for Updates") { Task { await updater.check() } }
                        .disabled(updater.isBusy)
                }
            }
            Text("Updates build the newest version from GitHub on this Mac (needs Apple's Command Line Tools), then ask you to restart the app. After an update, macOS may ask you to re-allow Accessibility.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mint)
        case .available(let commit, let summary, let date):
            VStack(alignment: .leading, spacing: 2) {
                Label("Update available · \(commit.prefix(7))", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Theme.orange)
                if !summary.isEmpty { Text(summary).font(.caption) }
                if let date { Text(date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
            }
        case .installing(let step):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: updater.progress).progressViewStyle(.linear).frame(width: 220)
                Text(step).font(.caption).foregroundStyle(.secondary)
            }
        case .readyToRestart:
            Label("Update installed. Restart to use it.", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mint)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                    .textSelection(.enabled)
                Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([Updater.logFile]) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}

/// Click "Change", then press the key or mouse button you want to hold.
/// Records a trigger by pressing it: the talk key, or the optional key that
/// replays Ilan's last reply.
private struct TalkTriggerRecorder: View {
    @ObservedObject var ptt: PushToTalk
    var target: PushToTalk.Target = .talk
    @ObservedObject var settings = AppSettings.shared

    private var recordingThis: Bool { ptt.recording == target }
    private var current: TalkTrigger? { target == .talk ? settings.talkTrigger : settings.replayTrigger }

    var body: some View {
        LabeledContent(target == .talk ? "Hold to talk" : "Replay last reply") {
            HStack(spacing: 10) {
                Text(recordingThis ? "Press a key or mouse button…" : current?.name ?? "None")
                    .font(.system(size: 12.5, weight: .semibold, design: recordingThis ? .default : .rounded))
                    .foregroundStyle(recordingThis ? Theme.orange : (current == nil ? .secondary : .primary))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .frame(minWidth: 150)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(recordingThis ? Theme.orange : Color.white.opacity(0.18), lineWidth: 1))
                if recordingThis {
                    Button("Cancel") { ptt.cancelRecording() }
                } else {
                    Button(current == nil ? "Set…" : "Change…") { ptt.beginRecording(target) }
                    if target == .replay, current != nil {
                        Button { settings.replayTrigger = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("No replay key")
                    }
                }
            }
        }
        .onDisappear { if recordingThis { ptt.cancelRecording() } }
        Text(note)
            .font(.caption).foregroundStyle(.secondary)
    }

    private var note: String {
        if recordingThis {
            return "Press any key (a modifier like right ⌥ on its own works too) or a mouse button other than left/right. Esc cancels."
        }
        if target == .replay {
            return current == nil
                ? "Optional: a key or mouse button that replays Ilan's last reply from any app. It cuts off whatever Ilan is saying; tapping the talk key stops the replay."
                : "Press it anywhere to hear Ilan's last reply again. It cuts off whatever Ilan is saying; tapping \(settings.talkTrigger.shortLabel) stops the replay."
        }
        switch settings.talkTrigger.kind {
        case .modifier: return "Hold it anywhere to talk, let go to send. Allow Accessibility so it works in every app."
        case .key: return "While Ilan Voice runs, this key only talks to Ilan and no longer types. Keys you rarely use, like F13–F19, work best."
        case .mouse: return "While Ilan Voice runs, this button only talks to Ilan and no longer does its usual job (e.g. Back in a browser)."
        }
    }
}

private struct MicrophonePicker: View {
    @ObservedObject var settings = AppSettings.shared
    @Local private var devices = AudioDevices.inputs()

    var body: some View {
        Picker("Microphone", selection: $settings.microphone) {
            Text(devices.contains(where: \.isBuiltIn) ? "Mac's built-in microphone" : "Built-in (none on this Mac, uses default)")
                .tag(MicrophoneChoice.builtIn)
            Text("System default").tag(MicrophoneChoice.system)
            Divider()
            ForEach(devices) { d in
                Text(d.name + (d.isBluetooth ? " (Bluetooth)" : "")).tag(d.uid)
            }
        }
        .onAppear { devices = AudioDevices.inputs() }
        Text("Recording through Bluetooth headphones switches them to low-quality call audio and garbles the start of each reply. The built-in microphone avoids that.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// The built-in run_shell tool: on/off, where and how long commands run, and
/// the allow-list of commands Ilan may run without asking.
private struct ShellSettings: View {
    @ObservedObject var settings = AppSettings.shared
    @Local private var confirmBypass = false

    /// Turning bypass on goes through a warning; turning it off is immediate.
    private var bypassBinding: Binding<Bool> {
        Binding(get: { settings.shellBypassPermissions },
                set: { on in if on { confirmBypass = true } else { settings.shellBypassPermissions = false } })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Let Ilan run bash commands on this Mac", isOn: $settings.shellEnabled)
                Text("Ilan never asks: commands on the allow-list run straight away, anything else is refused and Ilan tells you what to add. Changes apply to the next conversation (or Voice → Reconnect). Command output is sent to OpenAI as part of the conversation.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: bypassBinding) {
                    Text("Bypass all permissions").foregroundStyle(.red).fontWeight(.medium)
                }
                .disabled(!settings.shellEnabled)
                Text("Not bypassed: the file tools still never read or change SSH, AWS and GnuPG keys, the Keychain or Ilan's own secrets. Shell commands themselves are not limited.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.bypassActive {
                    Label("Any command runs, including ones that delete or change files, and Ilan can change any file. The file block list and the allow-list below are ignored.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .alert("Bypass all permissions?", isPresented: $confirmBypass) {
                Button("Turn On", role: .destructive) { settings.shellBypassPermissions = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Ilan will be able to run any bash command and change any file on this Mac without checks, including commands that delete files, change system settings, install software or send your data elsewhere. A misheard request or a mistake by the model can cause damage that can't be undone. Only turn this on if you understand the risk.")
            }
            Section {
                LabeledContent("Read files") { Text("Always on").foregroundStyle(.secondary) }
                // Shown on while bypass is on, since bypass allows file changes too.
                Toggle("Let Ilan edit, create and overwrite files", isOn: Binding(
                    get: { settings.fileChangesAllowed },
                    set: { settings.fileChangesEnabled = $0 }))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Never change these files or folders, one per line").font(.caption)
                    TextEditor(text: $settings.fileBlockList)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 50)
                        .scrollContentBackground(.hidden)
                }
                .disabled(!settings.fileChangesEnabled)
            } header: {
                Text("Files")
            } footer: {
                Text("Every change is backed up first to Ilan Voice's file-backups folder. SSH, AWS and GnuPG keys, the Keychain and Ilan's own secrets are never read or changed. File contents are sent to OpenAI as part of the conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(settings.bypassActive)
            .opacity(settings.bypassActive ? 0.45 : 1)
            Section("Running") {
                TextField("Working directory", text: $settings.shellDirectory)
                LabeledContent("Timeout") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.shellTimeout, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!settings.shellEnabled)
            Section {
                TextEditor(text: $settings.shellAllowList)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                let invalid = ShellTool.invalidRegexEntries(settings.shellAllowListEntries)
                if !invalid.isEmpty {
                    Label("Not a valid regex (ignored): \(invalid.joined(separator: "  "))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.orange)
                }
                Text("One entry per line. A plain line is a prefix that matches whole words, so \"ls\" does not allow \"lsof\". A line wrapped in slashes is a regular expression that must match the whole command, e.g. /kubectl -n [a-z-]+ get .*/. Pipes, && and ; are fine when every part is allowed; writing to files (>), $( ), backticks, & and file-changing flags such as find -delete are always refused.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("Allowed commands")
                    Spacer()
                    Button("Reset to Read-only Defaults") { settings.shellAllowList = ShellTool.defaultAllowList }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .disabled(!settings.shellEnabled || settings.bypassActive)
            .opacity(settings.bypassActive ? 0.45 : 1)
        }
        .formStyle(.grouped)
    }
}

/// One word or phrase per line; grounds transcription and the model's spelling.
/// The personal dictionary as a list: add a word, delete one, or import a
/// text file with one word or phrase per line.
private struct DictionarySettings: View {
    @Local private var terms = UserDictionary.terms()
    @Local private var newTerm = ""
    @Local private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Names, jargon and acronyms that speech recognition gets wrong, spelled the way you want them written. Ilan and the transcription model both use them. Changes apply to the next conversation (or Voice → Reconnect).")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Add a word or phrase", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .buttonStyle(.borderedProminent)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Import…", action: importFile)
                    .help("Add every line of a text file (one word or phrase per line).")
            }
            if terms.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "character.book.closed").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No words yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(terms, id: \.self) { term in
                        HStack {
                            Text(term).font(.system(size: 13))
                            Spacer()
                            Button { remove(term) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Delete \"\(term)\"")
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Text("\(terms.count) \(terms.count == 1 ? "word" : "words")").font(.caption).foregroundStyle(.secondary)
                if let note { Text("· \(note)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
        }
        .padding(20)
        .onAppear { terms = UserDictionary.terms() }
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        let added = UserDictionary.add([term])
        note = added == 0 ? "\"\(term)\" is already in the list" : nil
        newTerm = ""
        terms = UserDictionary.terms()
    }

    private func remove(_ term: String) {
        UserDictionary.remove(term)
        note = nil
        terms = UserDictionary.terms()
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a text file with one word or phrase per line."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try UserDictionary.importFile(url)
            note = "Imported \(result.added) new of \(result.read) from \(url.lastPathComponent)"
        } catch {
            note = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
        terms = UserDictionary.terms()
    }
}

/// The built-in web_search tool: provider, key and model.
/// The built-in web_search tool, shown as one section of the General tab.
private struct WebSearchSection: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Section {
            Toggle("Let Ilan search the web", isOn: $settings.webSearchEnabled)
            Group {
                Picker("Search with", selection: $settings.webSearchProvider) {
                    ForEach(WebSearchProvider.allCases) { Text($0.label).tag($0) }
                }
                APIKeyRow(title: "Gemini API key", provider: .gemini, key: $settings.geminiAPIKey)
                TextField("Gemini model", text: $settings.geminiModel)
            }
            .disabled(!settings.webSearchEnabled)
        } header: {
            HStack {
                Text("Web Search")
                Spacer()
                Text(status).font(.caption).foregroundStyle(settings.webSearchAvailable ? Theme.mint : Theme.orange)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("When a question needs fresh or factual information, Ilan calls the web_search tool. Gemini answers it with Google Search, and the answer and its sources appear in the transcript. Changes apply to the next conversation (or Reconnect).")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Get a Gemini API key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.caption)
            }
        }
    }

    private var status: String {
        if !settings.webSearchEnabled { return "Off" }
        return settings.webSearchAvailable ? "Ready" : "Needs a Gemini API key"
    }
}

extension Notification.Name {
    /// Posted before Settings is opened from a button, to land on General.
    static let showGeneralSettings = Notification.Name("IlanVoice.showGeneralSettings")
}

/// Opens Settings on the General tab. Use instead of `SettingsLink` and
/// `openSettings()` everywhere in the app.
struct GeneralSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .showGeneralSettings, object: nil)
            openSettings()
        } label: { label() }
    }
}

final class WeakWindow {
    weak var value: NSWindow?
}

/// Reports the window a SwiftUI view lives in.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

/// A native macOS slider with tick marks that snaps to them, like the
/// sliders in System Settings (e.g. mouse tracking speed).
private struct TickSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.numberOfTickMarks = Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.isContinuous = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if abs(slider.doubleValue - value) > 0.0001 { slider.doubleValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: TickSlider
        init(_ parent: TickSlider) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            // Snap away floating-point noise (0.9000000001 → 0.9).
            let snapped = (sender.doubleValue / parent.step).rounded() * parent.step
            parent.value = (snapped * 100).rounded() / 100
        }
    }
}

/// An API key is never shown or typed in place. The row says whether a key is
/// set (with a short hint such as "sk-…a1b2"); "Set API Key…" opens a sheet
/// where the new key is pasted, checked with the provider, and stored only
/// if the check passes.
private struct APIKeyRow: View {
    let title: String
    let provider: APIKeyCheck.Provider
    @Binding var key: String
    @Local private var editing = false
    @Local private var confirmRemove = false

    private var isSet: Bool { !key.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                if isSet {
                    Label(APIKeyCheck.hint(for: key), systemImage: "checkmark.seal.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.mint)
                } else {
                    Label("Not set", systemImage: "exclamationmark.circle")
                        .foregroundStyle(Theme.orange)
                }
                Button(isSet ? "Change…" : "Set API Key…") { editing = true }
                if isSet {
                    Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove this key")
                }
            }
        }
        .sheet(isPresented: $editing) {
            SetAPIKeySheet(title: title, provider: provider) { newKey in key = newKey }
        }
        .confirmationDialog("Remove the \(provider.name) API key?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { key = "" }
        }
    }
}

private struct SetAPIKeySheet: View {
    let title: String
    let provider: APIKeyCheck.Provider
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Local private var draft = ""
    @Local private var checking = false
    @Local private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set \(title)").font(.headline)
            Text("Paste your new \(provider.name) key. It is checked with \(provider.name) before it is saved, and it is never shown again.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Paste the key here", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit(save)
                .disabled(checking)
            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(Theme.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Checking with \(provider.name)…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Check & Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(checking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !checking else { return }
        checking = true
        error = nil
        Task { @MainActor in
            let outcome = await APIKeyCheck.check(key, provider: provider)
            checking = false
            switch outcome {
            case .valid:
                onSave(key)
                dismiss()
            case .invalid(let message):
                error = message
            }
        }
    }
}

/// Settings → General → iPhone: start the web server and pair the phone.
private struct PhoneSection: View {
    @ObservedObject var phone: PhoneServer
    @Local private var copied = false
    @Local private var confirmReset = false

    var body: some View {
        Section {
            HStack(spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch phone.status {
                case .stopped, .failed:
                    Button("Start Web Server") { phone.start() }.buttonStyle(.borderedProminent)
                case .starting:
                    ProgressView().controlSize(.small)
                case .running:
                    Button("Stop") { phone.stop() }
                }
            }
            if let url = phone.pairingURL {
                HStack(alignment: .top, spacing: 16) {
                    if let qr = PhoneServer.qrCode(for: url) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 132, height: 132)
                            .padding(8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan with the iPhone camera, open the page, then Share → Add to Home Screen.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(url)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled)
                        HStack(spacing: 12) {
                            Button(copied ? "Copied" : "Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                            }
                            Button("New Pairing Code…") { confirmReset = true }
                                .buttonStyle(.link)
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("iPhone")
        } footer: {
            Text("Talk to Ilan from your iPhone's home screen. Each iPhone has a conversation of its own (marked with an iPhone in the sidebar) and uses the same instructions, tools and settings as this Mac. Only your devices on Tailscale can reach the server, and only with the pairing code in the link.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Make a new pairing code?", isPresented: $confirmReset) {
            Button("New Pairing Code", role: .destructive) { phone.resetPairing() }
        } message: {
            Text("The current link stops working. Open the new link on your iPhone and add it to the home screen again.")
        }
    }

    private var statusDot: some View {
        let color: Color = switch phone.status {
        case .running: phone.connectedCount > 0 ? Theme.mint : Theme.mintDeep
        case .failed: Theme.orange
        default: Color.secondary.opacity(0.5)
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private var title: String {
        switch phone.status {
        case .stopped: "Web server is off"
        case .starting: "Starting…"
        case .running: phone.connectedCount == 0 ? "Web server is running"
            : phone.connectedCount == 1 ? "1 iPhone connected" : "\(phone.connectedCount) iPhones connected"
        case .failed: "Couldn't start the web server"
        }
    }

    private var detail: String {
        switch phone.status {
        case .stopped: "Needs Tailscale on this Mac and on the iPhone."
        case .starting: "Publishing it on your tailnet."
        case .running: phone.connectedCount > 0 ? "Hold the button on the iPhone to talk." : "Waiting for an iPhone."
        case .failed(let problem): problem
        }
    }
}
