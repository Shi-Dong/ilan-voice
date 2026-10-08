import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let store = ConversationStore()
    let mcp = MCPManager()
    let ptt = PushToTalk()
    let updater = Updater()
    lazy var session = VoiceSession(store: store, mcp: mcp)
    private var hud: FloatingHUD?
    /// Opts out of App Nap. Ilan Voice spends most of its life in the
    /// background waiting for the talk key; App Nap throttled its timers and
    /// network callbacks there, so a message sent from another app sat on
    /// "Thinking" until the server dropped the connection. This does not keep
    /// the Mac or its display awake.
    private var activity: NSObjectProtocol?
    private var started = false

    /// One-time startup. Called from the main window's `.task`, which runs
    /// again every time the window is reopened; a second run would reconnect
    /// (cutting off Ilan mid-sentence), add duplicate talk-key listeners and a
    /// second floating pill, and reload every MCP server.
    func start() {
        guard !started else { return }
        started = true
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Listening for the talk key and streaming voice to OpenAI")
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
        // With "Hide from Dock" on, the Dock icon follows the main window:
        // gone while it is closed (the app lives on in the menu bar), back
        // as soon as it opens again.
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard Self.isMain(note.object), AppSettings.shared.hideDockWhenClosed else { return }
            NSApp.setActivationPolicy(.accessory)
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard Self.isMain(note.object) else { return }
            Self.showInDock()
        }
    }

    private static func isMain(_ window: Any?) -> Bool {
        (window as? NSWindow)?.identifier?.rawValue == "main"
    }

    static func showInDock() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct IlanVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Ilan Voice", id: "main") {
            MainView(store: model.store, session: model.session, ptt: model.ptt, mcp: model.mcp, updater: model.updater)
                .frame(minWidth: 760, minHeight: 540)
                .task { model.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.store.flush()
                    ShellSessions.shared.closeAll()
                    model.updater.installPendingOnQuit()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.updater.check() }
                    NotificationCenter.default.post(name: .showGeneralSettings, object: nil)
                    // openSettings can't be read from the App struct; this is the
                    // action the standard Settings… menu item sends.
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { model.store.newConversation() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
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
            SettingsView(mcp: model.mcp, updater: model.updater, ptt: model.ptt)
        }

        MenuBarExtra {
            MenuBarMenu(session: model.session)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}

/// The menu under the menu bar icon. A View of its own because openWindow and
/// openSettings only work when read from a view's environment; read in the
/// App struct they silently do nothing.
private struct MenuBarMenu: View {
    let session: VoiceSession
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Show Ilan Voice") { showMainWindow() }
        Button("Play Next Unheard Reply") { session.playNextUnheard() }
        Button("Settings…") {
            // With the window closed the app is out of the Dock and not
            // active, so bring it back first; Settings opens once the app is
            // in front, otherwise it stays hidden behind other apps.
            showMainWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: .showGeneralSettings, object: nil)
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func showMainWindow() {
        AppDelegate.showInDock()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
