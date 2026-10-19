import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import os

/// Watches the recorded talk trigger everywhere, and records a new one.
///
/// Modifier keys arrive as `flagsChanged`: inside the app a local monitor is
/// enough; in other apps macOS only delivers them once Ilan Voice is trusted
/// under Privacy & Security → Accessibility. They are never swallowed.
///
/// Ordinary keys and mouse buttons go through an event tap (also needs
/// Accessibility) that sees them in every app and swallows them, so the key
/// doesn't type and a side button doesn't also go Back. Without the tap, local
/// monitors still make them work inside the app's own windows. The tap runs
/// on its own thread (see `TalkKeyTap`), so a busy main thread can't make
/// macOS switch it off and lose a press.
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
    /// The tap's side: which events to swallow, decided on the tap's thread.
    let tapState = TalkKeyTap()
    private var cancellables: Set<AnyCancellable> = []
    private var isDown = false
    private var replayDown = false
    private let settings = AppSettings.shared

    init() {
        // The tap's thread decides from a copy of the triggers, kept up to date here.
        settings.$talkTrigger.combineLatest(settings.$replayTrigger, $recording)
            .sink { [tapState] talk, replay, recording in
                tapState.update(.init(talk: talk, replay: replay, recording: recording != nil))
            }
            .store(in: &cancellables)
        tapState.deliver = { [weak self] event in self?.handleTapped(event) }
    }

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
    nonisolated static func matches(_ trigger: TalkTrigger?, kind: TalkTrigger.Kind, code: Int) -> Bool {
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

    /// Two quick taps of the talk key, fired on the second release. A tap only
    /// stops Ilan once no second tap follows (see `VoiceSession.pressToTalk`).
    var onDoubleTap: (() -> Void)?
    private var doubleTap = DoubleTapDetector()

    // MARK: Event tap

    /// Fails until Accessibility is granted; the timer retries.
    private func installTap() {
        guard AXIsProcessTrusted() else { return }
        tap = tapState.install()
    }

    /// A key or button the tap swallowed, now on the main thread.
    private func handleTapped(_ event: TalkKeyTap.Event) {
        switch event.kind {
        case .mouse: _ = handleMouse(button: event.code, down: event.down)
        default: _ = handleKey(code: event.code, down: event.down, characters: event.characters)
        }
    }
}

/// The event tap for the talk and replay triggers, on a thread of its own.
///
/// macOS switches a tap off when it doesn't answer an event in time (about a
/// second), and the event that did it is lost. On the main thread, a moment
/// of heavy work there (say the window redrawing a long conversation while
/// another app is in front) could do that mid-press: the talk button went
/// down, nothing recorded, and no pill showed. So the tap decides here, at
/// once, from a copy of the triggers, whether an event is ours (swallowed),
/// and hands it to the main thread to act on, in order. A busy main thread
/// now only makes a press start a little late.
final class TalkKeyTap: @unchecked Sendable {
    struct Triggers: Equatable {
        var talk: TalkTrigger
        var replay: TalkTrigger?
        /// Settings is waiting for a new trigger to be pressed.
        var recording: Bool
    }
    struct Event: Equatable {
        var kind: TalkTrigger.Kind
        var code: Int
        var down: Bool
        var characters: String?
    }
    /// Gets each swallowed event, on the main thread.
    @MainActor var deliver: ((Event) -> Void)?

    private let lock = NSLock()
    private var triggers = Triggers(talk: .rightOption, replay: nil, recording: false)
    private var port: CFMachPort?
    private let log = Logger(subsystem: "me.dongshi.ilan-voice", category: "talk-key")

    func update(_ new: Triggers) { lock.withLock { triggers = new } }

    /// Whether the tap swallows an event: the talk or replay trigger, or any
    /// key (and a usable mouse button, on its way down) while Settings
    /// records a new trigger. The same answers as PushToTalk.handleKey/handleMouse.
    static func swallows(_ t: Triggers, kind: TalkTrigger.Kind, code: Int, down: Bool) -> Bool {
        if t.recording { return kind == .mouse ? down && TalkTrigger.mouse(button: code) != nil : true }
        if PushToTalk.matches(t.replay, kind: kind, code: code) { return true }
        return PushToTalk.matches(t.talk, kind: kind, code: code)
    }

    /// One event, on the tap's thread: whether to swallow it. Never waits on
    /// the main thread; what to do about it is queued there.
    func process(kind: TalkTrigger.Kind, code: Int, down: Bool, characters: () -> String? = { nil }) -> Bool {
        let t = lock.withLock { triggers }
        guard Self.swallows(t, kind: kind, code: code, down: down) else { return false }
        let event = Event(kind: kind, code: code, down: down, characters: t.recording ? characters() : nil)
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { deliver?(event) } }
        return true
    }

    /// Creates the tap and runs it on its own thread; nil if macOS refuses
    /// (no Accessibility yet).
    func install() -> CFMachPort? {
        let types: [CGEventType] = [.keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: Self.callback, userInfo: refcon) else { return nil }
        port = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Ilan Voice talk key"
        thread.qualityOfService = .userInteractive
        thread.start()
        log.notice("tap installed on its own thread")
        return tap
    }

    /// Runs on the tap's thread. Returning nil swallows the event.
    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<TalkKeyTap>.fromOpaque(refcon).takeUnretainedValue()
        let swallowed: Bool
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            me.log.notice("tap switched off by macOS (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)); switching it back on")
            if let port = me.port { CGEvent.tapEnable(tap: port, enable: true) }
            swallowed = false
        case .keyDown, .keyUp:
            swallowed = me.process(kind: .key, code: Int(event.getIntegerValueField(.keyboardEventKeycode)), down: type == .keyDown,
                                   characters: { NSEvent(cgEvent: event)?.charactersIgnoringModifiers })
        case .otherMouseDown, .otherMouseUp:
            swallowed = me.process(kind: .mouse, code: Int(event.getIntegerValueField(.mouseEventButtonNumber)),
                                   down: type == .otherMouseDown)
        default:
            swallowed = false
        }
        return swallowed ? nil : Unmanaged.passUnretained(event)
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
