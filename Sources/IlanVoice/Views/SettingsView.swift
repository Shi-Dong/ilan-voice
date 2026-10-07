import SwiftUI

struct SettingsView: View {
    @ObservedObject var mcp: MCPManager

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AgentSettings().tabItem { Label("Agent", systemImage: "person.text.rectangle") }
            MCPSettings(mcp: mcp).tabItem { Label("MCP Tools", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 640, height: 520)
        .preferredColorScheme(.dark)
        .tint(Theme.mint)
    }
}

private struct GeneralSettings: View {
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
                Picker("Voice", selection: $settings.voice) {
                    ForEach(AppSettings.voices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Reasoning effort", selection: $settings.reasoningEffort) {
                    ForEach(AppSettings.reasoningEfforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
                TextField("Transcription model", text: $settings.transcriptionModel)
            }
            Section("Talking") {
                Picker("Hold to talk", selection: $settings.pushToTalkKey) {
                    ForEach(PushToTalkKey.allCases) { Text($0.label).tag($0) }
                }
                Picker("Replies", selection: $settings.outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("Real-time plays a reply as it is generated. Cached saves it and waits for you to press play (or Space). Transcripts and audio are always saved.")
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
