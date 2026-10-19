import AppKit
import Combine
import os
import SwiftUI

/// A small pill near the bottom of the screen that shows, over any app, that
/// Ilan is listening, with live voice bars and the name of the microphone
/// recording. After you let go it briefly says "Sent" and fades away. It
/// never takes focus and clicks pass through it.
@MainActor
final class FloatingHUD {
    private let panel: NSPanel
    private let model = HUDModel()
    private var cancellables: Set<AnyCancellable> = []
    private var hideWork: DispatchWorkItem?
    /// `log show --predicate 'subsystem == "me.dongshi.ilan-voice"'` shows
    /// each time the pill is asked to appear, in case it ever doesn't.
    private let log = Logger(subsystem: "me.dongshi.ilan-voice", category: "pill")
    private var showWork: DispatchWorkItem?
    /// Bumped by every show and hide: a fade-in or an order-out still on its
    /// way from an earlier one is dropped, so a hide right after a show can't
    /// be undone by that show's fade-in (which left the pill up for good).
    private var visibilityChange = 0
    private static let listeningDelay: TimeInterval = VoiceSession.minRecordingSeconds

    /// How long to wait before "Listening". A press over a busy Ilan records
    /// quietly until it is past the cutoff (see VoiceSession.pressToTalk), so
    /// when it goes live the wait is already over.
    static func listeningWait(recordedFor: TimeInterval) -> TimeInterval {
        max(0, listeningDelay - recordedFor)
    }

    init(session: VoiceSession) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: HUDView.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host

        session.$phase
            .removeDuplicates()
            .sink { [weak self, weak session] phase in
                self?.update(phase, recordedFor: session.map { Date().timeIntervalSince($0.recordStart) } ?? 0,
                             microphone: session?.microphoneName)
            }
            .store(in: &cancellables)
        session.pressEnded
            .sink { [weak self] outcome in self?.finish(outcome) }
            .store(in: &cancellables)
        session.$inputLevel
            .sink { [weak self] level in self?.model.push(level) }
            .store(in: &cancellables)
    }

    /// Recording starts the moment the key goes down, but the pill waits
    /// as long as the cutoff below which a recording is never sent: a quick
    /// tap is almost always meant to cut Ilan off, so it goes straight to
    /// "Stopped assistant speech" without flashing "Listening".
    private func update(_ phase: VoiceSession.Phase, recordedFor: TimeInterval, microphone: String?) {
        guard phase == .recording else {
            // A safety net: no longer recording, yet nothing said how the press
            // ended, so "Listening" (or its pending show) goes. "Sent" and
            // "Stopped" keep their moment.
            if model.mode == .listening {
                showWork?.cancel()
                if panel.isVisible { hide() }
            }
            return
        }
        hideWork?.cancel()
        showWork?.cancel()
        model.listen(microphone: microphone)
        let work = DispatchWorkItem { [weak self] in self?.show() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.listeningWait(recordedFor: recordedFor), execute: work)
    }

    /// How a press ended: "Sent to Ilan", "Stopped assistant speech" (a quick
    /// tap that cut Ilan off), or nothing for an accidental tap.
    private func finish(_ outcome: VoiceSession.PressOutcome) {
        hideWork?.cancel()
        showWork?.cancel()
        switch outcome {
        case .discarded:
            if panel.isVisible { hide() }
            return
        case .sent:
            guard panel.isVisible else { return }
            model.mode = .sent
        case .stoppedSpeech:
            model.mode = .stopped
            if !panel.isVisible { show() }
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func show() {
        // Sit above the Dock on the screen you are working on.
        let mouse = NSEvent.mouseLocation
        let focused = Self.focusedWindowFrame()
        let screens = NSScreen.screens
        let index = Self.screenIndex(focusedWindow: focused, mouse: mouse, screens: screens.map(\.frame))
        let screen = index.map { screens[$0] } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 28))
        }
        // The fade lives in SwiftUI, not in the window's alpha: AppKit window
        // fades don't run while Ilan Voice isn't the active app (always the
        // case once its window is closed), which left the pill on screen but
        // fully transparent.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        visibilityChange += 1
        let change = visibilityChange
        log.notice("show: mode=\(String(describing: self.model.mode), privacy: .public) screen=\(String(describing: screen?.localizedName), privacy: .public) focused=\(String(describing: focused), privacy: .public) mouse=\(String(describing: mouse), privacy: .public) screens=\(screens.count) active=\(NSApp.isActive)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visibilityChange == change else { return }
            self.model.shown = true
        }
        // In case it still doesn't appear: whether macOS actually shows it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.visibilityChange == change else { return }
            let seen = self.panel.occlusionState.contains(.visible)
            self.log.notice("shown: visible=\(seen) onScreen=\(String(describing: self.panel.screen?.localizedName), privacy: .public) frame=\(String(describing: self.panel.frame), privacy: .public)")
        }
    }

    /// Which screen the pill goes on (an index into `screens`): the one
    /// showing most of the window you are working in, else the one with the
    /// pointer, else nil (the main screen). Not just the pointer's: with
    /// Ilan Voice open on one display and another app focused on another,
    /// the pointer is often left on the first, and the pill appeared there,
    /// out of sight.
    static func screenIndex(focusedWindow: CGRect?, mouse: CGPoint, screens: [CGRect]) -> Int? {
        if let window = focusedWindow {
            let overlaps = screens.map { screen -> CGFloat in
                let common = screen.intersection(window)
                return common.isNull ? 0 : common.width * common.height
            }
            if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 { return best }
        }
        return screens.firstIndex { NSMouseInRect(mouse, $0, false) }
    }

    /// The front window of the app you are working in (in AppKit's screen
    /// coordinates), or nil if it has none on screen.
    private static func focusedWindowFrame() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primary = NSScreen.screens.first?.frame,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // Front to back: the first ordinary window of that app is its front one.
        for info in windows where info[kCGWindowOwnerPID as String] as? pid_t == pid && info[kCGWindowLayer as String] as? Int == 0 {
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.width > 50, bounds.height > 50 else { continue }
            return appKitFrame(bounds, primaryHeight: primary.height)
        }
        return nil
    }

    /// A window list frame (top-left origin, y down) in AppKit's screen
    /// coordinates (bottom-left origin of the primary screen, y up).
    static func appKitFrame(_ bounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    private func hide() {
        model.shown = false
        visibilityChange += 1
        let change = visibilityChange
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.visibilityChange == change else { return }
            self.panel.orderOut(nil)
        }
    }
}

@MainActor
final class HUDModel: ObservableObject {
    enum Mode { case listening, sent, stopped }
    static let barCount = 14

    @Published var mode: Mode = .listening
    /// Fades the pill in and out.
    @Published var shown = false
    @Published private(set) var levels = Array(repeating: Float(0), count: barCount)
    /// The microphone recording, named next to the voice bars while listening.
    @Published private(set) var microphone: String?
    /// Longer names are cut short so the pill stays small.
    static let microphoneMaxLength = 30

    /// A new recording: empty bars and the name of the microphone it uses.
    func listen(microphone name: String?) {
        mode = .listening
        microphone = Self.microphoneLabel(name)
        reset()
    }

    /// The name to show for a microphone, or nil to show none.
    static func microphoneLabel(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        guard name.count > microphoneMaxLength else { return name }
        return name.prefix(microphoneMaxLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    func push(_ level: Float) {
        guard mode == .listening else { return }
        levels.removeFirst()
        levels.append(level)
    }

    func reset() { levels = Array(repeating: 0, count: Self.barCount) }
}

private struct HUDView: View {
    /// Wide enough for the listening pill with a long microphone name; the
    /// pill itself is only as wide as its content, centred in the panel.
    static let panelSize = CGSize(width: 400, height: 44)
    @ObservedObject var model: HUDModel

    var body: some View {
        pill
            .opacity(model.shown ? 1 : 0)
            .animation(.easeOut(duration: model.shown ? 0.12 : 0.25), value: model.shown)
    }

    private var pill: some View {
        HStack(spacing: 9) {
            AppIcon(size: 22)
            if model.mode == .listening {
                HStack(alignment: .center, spacing: 2.5) {
                    ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: 3, height: 4 + CGFloat(level) * 18)
                    }
                }
                .frame(height: 22)
                .animation(.easeOut(duration: 0.08), value: model.levels)
                Circle()
                    .fill(Color(red: 1, green: 0.42, blue: 0.42))
                    .frame(width: 7, height: 7)
                if let microphone = model.microphone {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(microphone)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)  // only if wide letters overflow the panel
                    }
                    .foregroundStyle(Theme.textDim)
                }
            } else {
                Label(model.mode == .stopped ? "Stopped assistant speech" : "Sent to Ilan",
                      systemImage: model.mode == .stopped ? "stop.fill" : "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        // Liquid Glass over whatever app is below, tinted dark so the bars read.
        .glassEffect(.regular.tint(Theme.ink.opacity(0.6)), in: Capsule())
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .animation(.easeInOut(duration: 0.15), value: model.mode)
    }
}
