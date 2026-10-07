import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let store = ConversationStore()
    let mcp = MCPManager()
    let ptt = PushToTalk()
    let updater = Updater()
    lazy var session = VoiceSession(store: store, mcp: mcp)
    private var hud: FloatingHUD?

    func start() {
        ptt.onPress = { [weak self] in self?.session.pressToTalk() }
        ptt.onRelease = { [weak self] in self?.session.releaseToTalk() }
        ptt.start()
        hud = FloatingHUD(session: session)
        Task { await updater.check() }
        Task {
            await mcp.reload()
            session.connect()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct IlanVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        Window("Ilan Voice", id: "main") {
            MainView(store: model.store, session: model.session, ptt: model.ptt, mcp: model.mcp, updater: model.updater)
                .frame(minWidth: 760, minHeight: 540)
                .task { model.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.store.flush()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.updater.check() }
                    openSettings()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { model.store.newConversation() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Voice") {
                Button("Play Next Unheard Reply") { model.session.playNextUnheard() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Stop Playback") { model.session.clips.stop() }
                    .keyboardShortcut(".")
                Divider()
                Button("Reconnect") { model.session.connect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(mcp: model.mcp, updater: model.updater)
        }

        MenuBarExtra {
            Button("Show Ilan Voice") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
            }
            Button("Play Next Unheard Reply") { model.session.playNextUnheard() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "waveform.circle.fill")
        }
    }
}
