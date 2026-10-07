import SwiftUI

struct SettingsView: View {
    @ObservedObject var mcp: MCPManager
    @ObservedObject var updater: Updater
    @ObservedObject var ptt: PushToTalk

    var body: some View {
        TabView {
            GeneralSettings(updater: updater, ptt: ptt).tabItem { Label("General", systemImage: "gearshape") }
            AgentSettings().tabItem { Label("Agent", systemImage: "person.text.rectangle") }
            MCPSettings(mcp: mcp).tabItem { Label("MCP Tools", systemImage: "wrench.and.screwdriver") }
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
                Picker("Reasoning effort", selection: $settings.reasoningEffort) {
                    ForEach(AppSettings.reasoningEfforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                TextField("Transcription model", text: $settings.transcriptionModel)
                TextField("Title model", text: $settings.titleModel)
                    .help("Names each conversation (30 characters max) from its 10 latest messages after every reply.")
            }
            Section("Talking") {
                TalkTriggerRecorder(ptt: ptt)
                Picker("Replies", selection: $settings.outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Real-time plays a reply as it is generated. Cached saves it and waits for you to press play (or Space). Transcripts and audio are always saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            UpdatesSection(updater: updater)
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
