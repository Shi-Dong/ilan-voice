import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var mcp: MCPManager
    @ObservedObject var updater: Updater
    @ObservedObject var ptt: PushToTalk

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
            GeneralSettings(updater: updater, ptt: ptt).tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
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
    @ObservedObject var settings = AppSettings.shared
    @Local private var reveal = false

    var body: some View {
        Form {
            UpdatesSection(updater: updater)
            Section("OpenAI") {
                HStack {
                    if reveal {
                        TextField("API key", text: $settings.apiKey)
                    } else {
                        SecureField("API key", text: $settings.apiKey)
                    }
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
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
                Picker("Replies", selection: $settings.outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Real-time plays a reply as it is generated. Cached saves it and waits for you to press play (or Space). Transcripts and audio are always saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            WebSearchSection()
            Section("Data") {
                LabeledContent("Folder") {
                    Button("Open in Finder") { NSWorkspace.shared.open(Paths.root) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSettings: View {
    @Local private var text = Paths.loadAgent()
    @Local private var saved = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("agent.md — the instructions Ilan follows in every conversation. Changes apply to the next conversation you open.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: text) { _, _ in saved = false }
            HStack {
                Button("Reveal File") { NSWorkspace.shared.activateFileViewerSelecting([Paths.agentFile]) }
                Button("Reset to Default") { text = Paths.defaultAgent }
                Spacer()
                if saved { Label("Saved", systemImage: "checkmark").foregroundStyle(.secondary).font(.caption) }
                Button("Save") {
                    try? text.write(to: Paths.agentFile, atomically: true, encoding: .utf8)
                    saved = true
                }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}

private struct MCPSettings: View {
    @ObservedObject var mcp: MCPManager
    @Local private var text = (try? String(contentsOf: Paths.mcpFile, encoding: .utf8)) ?? Paths.defaultMCP
    @Local private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("mcp.json uses the same shape as Claude Code: each server has a \"url\" (+ optional \"headers\") or a \"command\" (+ \"args\", \"env\").")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Servers").font(.headline)
                    if mcp.loading { ProgressView().controlSize(.small) }
                    ForEach(mcp.servers) { s in
                        HStack(alignment: .top, spacing: 6) {
                            Circle().fill(s.ok ? Theme.mint : Theme.orange).frame(width: 7, height: 7).padding(.top, 5)
                            VStack(alignment: .leading) {
                                Text(s.name).font(.system(size: 12, weight: .medium))
                                Text(s.state).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                    Spacer()
                }
                .frame(width: 190)
            }
            HStack {
                Button("Import from Claude Code") {
                    do {
                        let n = try MCPManager.importFromClaudeCode()
                        text = (try? String(contentsOf: Paths.mcpFile, encoding: .utf8)) ?? text
                        note = "Imported \(n) servers."
                        Task { await mcp.reload() }
                    } catch { note = error.localizedDescription }
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Save & Reconnect") {
                    guard (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil else {
                        note = "That is not valid JSON."
                        return
                    }
                    try? text.write(to: Paths.mcpFile, atomically: true, encoding: .utf8)
                    note = "Saved. New tools apply to the next conversation."
                    Task { await mcp.reload() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
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
                    Button("Install & Relaunch") { Task { await updater.install() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Check for Updates") { Task { await updater.check() } }
                        .disabled(updater.isBusy)
                }
            }
            Text("Updates build the newest version from GitHub on this Mac (needs Apple's Command Line Tools), then restart the app. After an update, macOS may ask you to re-allow Accessibility.")
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
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(step) }
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
private struct TalkTriggerRecorder: View {
    @ObservedObject var ptt: PushToTalk
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        LabeledContent("Hold to talk") {
            HStack(spacing: 10) {
                Text(ptt.isRecording ? "Press a key or mouse button…" : settings.talkTrigger.name)
                    .font(.system(size: 12.5, weight: .semibold, design: ptt.isRecording ? .default : .rounded))
                    .foregroundStyle(ptt.isRecording ? Theme.orange : .primary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .frame(minWidth: 150)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(ptt.isRecording ? Theme.orange : Color.white.opacity(0.18), lineWidth: 1))
                if ptt.isRecording {
                    Button("Cancel") { ptt.cancelRecording() }
                } else {
                    Button("Change…") { ptt.beginRecording() }
                }
            }
        }
        .onDisappear { ptt.cancelRecording() }
        Text(note)
            .font(.caption).foregroundStyle(.secondary)
    }

    private var note: String {
        if ptt.isRecording {
            return "Press any key (a modifier like right ⌥ on its own works too) or a mouse button other than left/right. Esc cancels."
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

    var body: some View {
        Form {
            Section {
                Toggle("Let Ilan run bash commands on this Mac", isOn: $settings.shellEnabled)
                Text("Ilan never asks: commands on the allow-list run straight away, anything else is refused and Ilan tells you what to add. Changes apply to the next conversation (or Voice → Reconnect). Command output is sent to OpenAI as part of the conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            .disabled(!settings.shellEnabled)
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
    @Local private var reveal = false

    var body: some View {
        Section {
            Toggle("Let Ilan search the web", isOn: $settings.webSearchEnabled)
            Group {
                Picker("Search with", selection: $settings.webSearchProvider) {
                    ForEach(WebSearchProvider.allCases) { Text($0.label).tag($0) }
                }
                HStack {
                    if reveal {
                        TextField("Gemini API key", text: $settings.geminiAPIKey)
                    } else {
                        SecureField("Gemini API key", text: $settings.geminiAPIKey)
                    }
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
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
