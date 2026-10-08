import SwiftUI

struct MainView: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var session: VoiceSession
    @ObservedObject var ptt: PushToTalk
    @ObservedObject var mcp: MCPManager
    @ObservedObject var updater: Updater
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            ChatView(store: store, session: session, ptt: ptt, mcp: mcp, updater: updater)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .tint(Theme.mint)
        .onChange(of: store.selectedID) { _, _ in
            session.clips.stop()
            session.connect()
        }
    }
}

struct Sidebar: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var shells = ShellSessions.shared
    @Local private var renaming: UUID?
    @Local private var draft = ""

    var body: some View {
        List(selection: $store.selectedID) {
            ForEach(store.conversations) { conv in
                VStack(alignment: .leading, spacing: 3) {
                    if renaming == conv.id {
                        TextField("Title", text: $draft)
                            .textFieldStyle(.plain)
                            .onSubmit { store.rename(conv.id, to: draft); renaming = nil }
                    } else {
                        HStack {
                            Text(conv.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            if shells.isOpen(conv.id) {
                                // An open bash session: click for the option to close it.
                                Menu {
                                    Text("A bash session is open in this conversation")
                                    Button("Close Bash Session", role: .destructive) { shells.close(conv.id) }
                                } label: {
                                    Image(systemName: "terminal.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.mint)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Bash session open. Click to close it.")
                            }
                            if conv.unheardCount > 0 {
                                Text("\(conv.unheardCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Theme.orange, in: Capsule())
                                    .foregroundStyle(Theme.ink)
                            }
                        }
                    }
                    Text(conv.updatedAt, format: .relative(presentation: .named))
                        .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
                .padding(.vertical, 3)
                .tag(conv.id)
                .contextMenu {
                    Button("Rename") { draft = conv.title; renaming = conv.id }
                    Button("Show Transcript in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Paths.conversation(conv.id).appendingPathComponent("transcript.md")])
                    }
                    if shells.isOpen(conv.id) {
                        Button("Close Bash Session") { shells.close(conv.id) }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { shells.close(conv.id); store.delete(conv.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button { store.newConversation() } label: { Image(systemName: "square.and.pencil") }
                    .help("New conversation (⇧⌘O)")
            }
        }
    }
}

struct ChatView: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var session: VoiceSession
    @ObservedObject var ptt: PushToTalk
    @ObservedObject var mcp: MCPManager
    @ObservedObject var updater: Updater
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        let conv = store.selected
        VStack(spacing: 0) {
            header(conv)
            Divider().overlay(Theme.hairline)
            ZStack {
                if let conv, !conv.messages.isEmpty {
                    messages(conv)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer(conv)
        }
        .background(Theme.background)
        .navigationTitle("")
    }

    private func header(_ conv: Conversation?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conv?.title ?? "Ilan Voice").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(Theme.color(for: session.phase)).frame(width: 7, height: 7)
                    Text(session.phase.label)
                    Text("·")
                    Text(settings.model)
                    if !mcp.tools.isEmpty {
                        Text("·")
                        Text("\(mcp.tools.count) tools")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
            }
            Spacer()
            if updater.updateAvailable {
                GeneralSettingsButton {
                    Label("Update", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(Theme.orange)
                }
                .buttonStyle(.plain)
                .help("A newer version is on GitHub. Open Settings to install it.")
            }
            Picker("Output", selection: $settings.outputMode) {
                ForEach(OutputMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            .help("Real-time plays replies as they arrive; Cached keeps them until you press play.")
            Button { session.connect() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                    .rotationEffect(.degrees(session.phase == .connecting ? 180 : 0))
                    .animation(.easeInOut(duration: 0.4), value: session.phase == .connecting)
                    .frame(width: 30, height: 26)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.phase == .recording || session.phase == .connecting)
            .help("Reconnect (⇧⌘R): start a fresh session so changes to agent.md, the dictionary, tools and voice take effect. The conversation is kept.")
            GeneralSettingsButton {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 30, height: 26)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func messages(_ conv: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(conv.messages) { msg in
                        MessageRow(message: msg, session: session, clips: session.clips).id(msg.id)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 24).padding(.vertical, 18)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: conv.messages) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            AppIcon(size: 88).shadow(color: Theme.mint.opacity(0.25), radius: 30)
            Text("Hold \(settings.talkTrigger.shortLabel) and speak")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("Let go to send. Ilan answers out loud\(settings.outputMode == .cached ? " — replies wait for you to press play" : "").")
                .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    /// A slim bar under the conversation: notices on the left, and in the
    /// bottom-right corner the hint, the "play new" button and a small talk button.
    private func footer(_ conv: Conversation?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let err = session.errorMessage, !(err == VoiceSession.missingKeyMessage && !settings.apiKey.isEmpty) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                        Text(err).font(.system(size: 12)).lineLimit(2)
                        Button { session.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                }
                if !ptt.trusted {
                    Button { ptt.requestAccessibility() } label: {
                        Label("Allow Accessibility so \(settings.talkTrigger.shortLabel) works in every app", systemImage: "hand.raised.fill")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim)
                }
            }
            Spacer(minLength: 12)
            Text(hint)
                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .lineLimit(1)
            if let unheard = conv?.unheardCount, unheard > 0 {
                Button { session.playNextUnheard() } label: {
                    Label("Play \(unheard) new", systemImage: "play.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Theme.orange, in: Capsule())
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .transition(.scale.combined(with: .opacity))
            }
            // The orb is drawn at 150 pt; scaled down to a ~56 pt corner button.
            TalkOrb(session: session)
                .scaleEffect(0.4)
                .frame(width: 60, height: 60)
        }
        .animation(.spring(response: 0.3), value: conv?.unheardCount)
        .padding(.leading, 20).padding(.trailing, 14).padding(.vertical, 8)
    }

    private var hint: String {
        switch session.phase {
        case .recording: "Listening — release to send"
        case .speaking: "Hold \(settings.talkTrigger.shortLabel) to interrupt"
        default: "Hold \(settings.talkTrigger.shortLabel) to talk"
        }
    }
}
