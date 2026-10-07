import AppKit
import ApplicationServices

/// Watches the chosen modifier key everywhere. Inside the app a local monitor
/// is enough; in other apps macOS only delivers the events once Ilan Voice is
/// trusted under Privacy & Security → Accessibility.
@MainActor
final class PushToTalk: ObservableObject {
    @Published private(set) var trusted = AXIsProcessTrusted()
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false
    private let settings = AppSettings.shared

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
            return event
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trusted = AXIsProcessTrusted() }
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func handle(_ event: NSEvent) {
        let key = settings.pushToTalkKey
        guard event.keyCode == key.keyCode else { return }
        let down = event.modifierFlags.contains(key.flag)
        guard down != isDown else { return }
        isDown = down
        down ? onPress?() : onRelease?()
    }
}
