import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Watches the recorded talk trigger everywhere, and records a new one.
///
/// Modifier keys arrive as `flagsChanged`: inside the app a local monitor is
/// enough; in other apps macOS only delivers them once Ilan Voice is trusted
/// under Privacy & Security → Accessibility. They are never swallowed.
///
/// Ordinary keys and mouse buttons go through an event tap (also needs
/// Accessibility) that sees them in every app and swallows them, so the key
/// doesn't type and a side button doesn't also go Back. Without the tap, local
/// monitors still make them work inside the app's own windows.
@MainActor
final class PushToTalk: ObservableObject {
    @Published private(set) var trusted = AXIsProcessTrusted()
    /// True while Settings is waiting for the user to press a new trigger.
    /// Which trigger Settings is waiting for the user to press, if any.
    enum Target { case talk, replay }
    @Published private(set) var recording: Target?
    var isRecording: Bool { recording != nil }
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// The replay trigger went down (fires once per press, never on repeats).
    var onReplay: (() -> Void)?

    private var monitors: [Any] = []
    private var tap: CFMachPort?
    private var isDown = false
    private var replayDown = false
    private let settings = AppSettings.shared

    func start() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            Task { @MainActor in self?.handleFlags(event) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.handleFlags(event)
            return event
        }) { monitors.append(m) }
        // In-app fallback for keys and mouse buttons when there is no tap.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .otherMouseDown, .otherMouseUp], handler: { [weak self] event in
            guard let self else { return event }
            let swallowed = switch event.type {
            case .keyDown, .keyUp:
                self.handleKey(code: Int(event.keyCode), down: event.type == .keyDown, characters: event.charactersIgnoringModifiers)
            default:
                self.handleMouse(button: event.buttonNumber, down: event.type == .otherMouseDown)
            }
            return swallowed ? nil : event
        }) { monitors.append(m) }
        installTap()
        // Re-check right away when the user comes back from System Settings.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.trusted = AXIsProcessTrusted()
                if self.tap == nil { self.installTap() }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.trusted = AXIsProcessTrusted()
                if self.tap == nil { self.installTap() }
            }
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Recording a new trigger

    func beginRecording(_ target: Target = .talk) {
        if isDown { setDown(false) }
        recording = target
    }

    func cancelRecording() { recording = nil }

    private func record(_ trigger: TalkTrigger) {
        let (talk, replay) = Self.assign(trigger, to: recording ?? .talk,
                                         talk: settings.talkTrigger, replay: settings.replayTrigger)
        settings.talkTrigger = talk
        settings.replayTrigger = replay
        recording = nil
    }

    /// The two triggers after recording `trigger` for `target`. One key can't
    /// do both jobs: giving the talk key to replay is refused, and taking the
    /// replay key for talking clears replay.
    static func assign(_ trigger: TalkTrigger, to target: Target, talk: TalkTrigger,
                       replay: TalkTrigger?) -> (talk: TalkTrigger, replay: TalkTrigger?) {
        switch target {
        case .talk: return (trigger, replay == trigger ? nil : replay)
        case .replay: return (talk, trigger == talk ? replay : trigger)
        }
    }

    /// Whether an event of `kind` with `code` is `trigger`.
    static func matches(_ trigger: TalkTrigger?, kind: TalkTrigger.Kind, code: Int) -> Bool {
        guard let trigger else { return false }
        return trigger.kind == kind && trigger.code == code
    }

    /// Replay fires on the press only; holding the key or its repeats do nothing more.
    private func setReplayDown(_ down: Bool) {
        guard down != replayDown else { return }
        replayDown = down
        if down { onReplay?() }
    }

    // MARK: Event handling. Each returns true when the event should be swallowed.

    private func handleFlags(_ event: NSEvent) {
        let code = Int(event.keyCode)
        if isRecording {
            // Record a modifier the moment it goes down.
            if let trigger = TalkTrigger.modifier(keyCode: code), let flag = trigger.modifierFlag,
               event.modifierFlags.contains(flag) {
                record(trigger)
            }
            return
        }
        if Self.matches(settings.replayTrigger, kind: .modifier, code: code), let flag = settings.replayTrigger?.modifierFlag {
            setReplayDown(event.modifierFlags.contains(flag))
            return
        }
        let trigger = settings.talkTrigger
        guard trigger.kind == .modifier, trigger.code == code, let flag = trigger.modifierFlag else { return }
        setDown(event.modifierFlags.contains(flag))
    }

    private func handleKey(code: Int, down: Bool, characters: String?) -> Bool {
        if isRecording {
            guard down else { return true }
            if code == kVK_Escape { cancelRecording() } else { record(.key(keyCode: code, characters: characters)) }
            return true
        }
        if Self.matches(settings.replayTrigger, kind: .key, code: code) {
            setReplayDown(down)
            return true
        }
        let trigger = settings.talkTrigger
        guard trigger.kind == .key, trigger.code == code else { return false }
        setDown(down)  // key repeats are absorbed by setDown's same-state guard
        return true
    }

    private func handleMouse(button: Int, down: Bool) -> Bool {
        if isRecording {
            guard down, let trigger = TalkTrigger.mouse(button: button) else { return false }
            record(trigger)
            return true
        }
        if Self.matches(settings.replayTrigger, kind: .mouse, code: button) {
            setReplayDown(down)
            return true
        }
        let trigger = settings.talkTrigger
        guard trigger.kind == .mouse, trigger.code == button else { return false }
        setDown(down)
        return true
    }

    private func setDown(_ down: Bool) {
        guard down != isDown else { return }
        isDown = down
        down ? onPress?() : onRelease?()
        if doubleTap.record(down: down, at: Date()) { onDoubleTap?() }
    }

    /// Two quick taps of the talk key. Each tap still does what a single tap
    /// does (it stops Ilan speaking); the second one also fires this.
    var onDoubleTap: (() -> Void)?
    private var doubleTap = DoubleTapDetector()

    // MARK: Event tap

    /// Fails until Accessibility is granted; the timer retries.
    private func installTap() {
        guard AXIsProcessTrusted() else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: PushToTalk.tapCallback, userInfo: refcon) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
    }

    /// Runs on the main run loop. Returning nil swallows the event.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<PushToTalk>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated {
            let swallowed: Bool
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                swallowed = false
            case .keyDown, .keyUp:
                let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                swallowed = me.handleKey(code: code, down: type == .keyDown,
                                         characters: NSEvent(cgEvent: event)?.charactersIgnoringModifiers)
            case .otherMouseDown, .otherMouseUp:
                let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
                swallowed = me.handleMouse(button: button, down: type == .otherMouseDown)
            default:
                swallowed = false
            }
            return swallowed ? nil : Unmanaged.passUnretained(event)
        }
    }
}

/// Spots a double tap of the talk key: two short presses, the second starting
/// soon after the first ended. Pure timing, so it can be tested.
struct DoubleTapDetector {
    /// A press shorter than this is a tap (the same cutoff below which a
    /// recording is never sent).
    var maxTap: TimeInterval = 0.2  // = VoiceSession.minRecordingSeconds (checked by a test)
    /// The second tap must start within this long after the first ends.
    var maxGap: TimeInterval = 0.35

    private var pressedAt: Date?
    private var lastTapEnd: Date?
    private var secondPress = false

    /// Feed every press and release; returns true on the release that
    /// completes a double tap.
    mutating func record(down: Bool, at time: Date) -> Bool {
        if down {
            secondPress = lastTapEnd.map { time.timeIntervalSince($0) <= maxGap } ?? false
            pressedAt = time
            return false
        }
        guard let start = pressedAt else { return false }
        pressedAt = nil
        let isTap = time.timeIntervalSince(start) < maxTap
        defer { if !isTap { lastTapEnd = nil } }
        guard isTap else { return false }
        if secondPress {
            secondPress = false
            lastTapEnd = nil  // a third tap starts over
            return true
        }
        lastTapEnd = time
        return false
    }
}
