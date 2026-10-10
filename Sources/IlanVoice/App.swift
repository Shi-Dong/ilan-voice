import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let store = ConversationStore()
    let mcp = MCPManager()
    let ptt = PushToTalk()
    let updater = Updater()
    lazy var session = VoiceSession(store: store, mcp: mcp)
    lazy var phone = PhoneServer(store: store, mcp: mcp)
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
        // Double-tap: each tap already stopped Ilan; now bring the window
        // forward with the cursor in the message box.
        ptt.onDoubleTap = {
            AppDelegate.showMainWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ComposerModel.shared.focusRequests.send() }
        }
        ptt.onReplay = { [weak self] in
            guard let self, self.session.phase != .recording else { return }
            self.session.replayLast()
        }
        ptt.start()
        hud = FloatingHUD(session: session)
        updater.startAutoCheck()
        Task {
            await mcp.reload()
            session.connect()
            if AppSettings.shared.phoneServerEnabled { phone.start() }
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

    /// Opening the app while it runs with no window (from Raycast, Spotlight,
    /// Finder or the Dock) brings the main window back, like Wispr Flow does,
    /// instead of only making the app active.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        Self.showMainWindow()
        return false
    }

    /// SwiftUI only reopens a closed window through openWindow, which lives in
    /// a view's environment; MenuBarLabel (always on screen) does it on request.
    static func showMainWindow() {
        showInDock()
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        // Fallback if SwiftUI kept the window object around but hidden.
        DispatchQueue.main.async {
            let main = NSApp.windows.first { $0.identifier?.rawValue == "main" }
            if let main, !main.isVisible { main.makeKeyAndOrderFront(nil) }
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
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

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
                    openSettings()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { model.store.newConversation() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Voice") {
                Button("Play Next Unheard Reply") { model.session.playNextUnheard() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Replay Last Reply") { model.session.replayLast() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Stop Playback") { model.session.clips.stop() }
                    .keyboardShortcut(".")
                Divider()
                Button("Reconnect") { model.session.connect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(mcp: model.mcp, updater: model.updater, ptt: model.ptt, phone: model.phone)
        }

        MenuBarExtra {
            Button("Show Ilan Voice") {
                AppDelegate.showInDock()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Play Next Unheard Reply") { model.session.playNextUnheard() }
            Button("Replay Last Reply") { model.session.replayLast() }
            Button("Settings…") {
                // With the window closed the app is out of the Dock and not
                // active, so Settings would open behind other apps (or not at
                // all). Bring the app back first, then open Settings on top.
                AppDelegate.showInDock()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .showGeneralSettings, object: nil)
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            MenuBarLabel()
        }
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("IlanVoice.openMainWindow")
}

/// The menu bar icon. It is always on screen, so it also carries openWindow
/// for AppDelegate, which has no SwiftUI environment of its own.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image)
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                openWindow(id: "main")
            }
    }
}
