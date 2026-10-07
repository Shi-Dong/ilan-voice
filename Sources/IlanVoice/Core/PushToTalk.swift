import AppKit
import ApplicationServices

/// Watches the chosen talk key or mouse button everywhere.
///
/// Modifier keys: inside the app a local monitor is enough; in other apps
/// macOS only delivers the events once Ilan Voice is trusted under
/// Privacy & Security → Accessibility.
///
/// Mouse buttons: an event tap (also needs Accessibility) sees the button in
/// every app and swallows it, so a side button does not also navigate Back.
/// Without the tap, a local monitor still works inside the app's own window.
@MainActor
final class PushToTalk: ObservableObject {
    @Published private(set) var trusted = AXIsProcessTrusted()
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var mouseMonitor: Any?
    private var mouseTap: CFMachPort?
    private var isDown = false
    private let settings = AppSettings.shared

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handleKey(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handleKey(event) }
            return event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
            guard let self, event.buttonNumber == self.settings.pushToTalkKey.mouseButton else { return event }
            self.setDown(event.type == .otherMouseDown)
            return nil
        }
        installMouseTap()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.trusted = AXIsProcessTrusted()
                if self.mouseTap == nil { self.installMouseTap() }
            }
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func handleKey(_ event: NSEvent) {
        let key = settings.pushToTalkKey
        guard let code = key.keyCode, event.keyCode == code else { return }
        setDown(event.modifierFlags.contains(key.flag))
    }

    private func setDown(_ down: Bool) {
        guard down != isDown else { return }
        isDown = down
        down ? onPress?() : onRelease?()
    }

    // MARK: Mouse event tap

    /// Fails (returns nil) until Accessibility is granted; the timer retries.
    private func installMouseTap() {
        guard AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: PushToTalk.tapCallback, userInfo: refcon) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        mouseTap = tap
    }

    /// Runs on the main run loop. Returning nil swallows the click.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<PushToTalk>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.mouseTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard button == me.settings.pushToTalkKey.mouseButton else { return Unmanaged.passUnretained(event) }
            me.setDown(type == .otherMouseDown)
            return nil
        }
    }
}
