import AppKit
import Combine
import os
import SwiftUI

/// A small pill near the bottom of the screen that shows, over any app, that
/// Ilan is listening, with live voice bars. After you let go it briefly says
/// "Sent" and fades away. It never takes focus and clicks pass through it.
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
    private static let listeningDelay: TimeInterval = VoiceSession.minRecordingSeconds

    init(session: VoiceSession) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
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
            .sink { [weak self] phase in self?.update(phase) }
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
    private func update(_ phase: VoiceSession.Phase) {
        guard phase == .recording else { return }
        hideWork?.cancel()
        showWork?.cancel()
        model.mode = .listening
        model.reset()
        let work = DispatchWorkItem { [weak self] in self?.show() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.listeningDelay, execute: work)
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
        // Sit above the Dock on whichever screen the pointer is on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
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
        log.info("show: mode=\(String(describing: self.model.mode), privacy: .public) screen=\(String(describing: self.panel.screen?.localizedName), privacy: .public) active=\(NSApp.isActive)")
        DispatchQueue.main.async { [weak self] in self?.model.shown = true }
    }

    private func hide() {
        model.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.model.shown else { return }
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

    func push(_ level: Float) {
        guard mode == .listening else { return }
        levels.removeFirst()
        levels.append(level)
    }

    func reset() { levels = Array(repeating: 0, count: Self.barCount) }
}

private struct HUDView: View {
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
                            .fill(Theme.mint)
                            .frame(width: 3, height: 4 + CGFloat(level) * 18)
                    }
                }
                .frame(height: 22)
                .animation(.easeOut(duration: 0.08), value: model.levels)
                Circle()
                    .fill(Color(red: 1, green: 0.42, blue: 0.42))
                    .frame(width: 7, height: 7)
            } else {
                Label(model.mode == .stopped ? "Stopped assistant speech" : "Sent to Ilan",
                      systemImage: model.mode == .stopped ? "stop.fill" : "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.mint)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            Capsule().fill(Theme.ink.opacity(0.92))
                .overlay(Capsule().stroke(Theme.mint.opacity(0.35), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .frame(width: 240, height: 44)
        .animation(.easeInOut(duration: 0.15), value: model.mode)
    }
}
