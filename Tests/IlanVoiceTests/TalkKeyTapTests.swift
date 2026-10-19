import Carbon.HIToolbox
import Foundation
@testable import IlanVoice

/// The talk key's event tap answers macOS on its own thread, so a busy main
/// thread can't get it switched off and lose a press.
@MainActor
func registerTalkKeyTapTests() {
    let button6 = TalkTrigger(kind: .mouse, code: 5, name: "Mouse button 6")
    let f13 = TalkTrigger(kind: .key, code: kVK_F13, name: "F13")
    /// Runs one event through the tap the way macOS does, off the main thread;
    /// nil if it didn't answer within a second.
    func tapped(_ tap: TalkKeyTap, _ kind: TalkTrigger.Kind, _ code: Int, down: Bool) -> Bool? {
        let answered = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var swallowed = false
        DispatchQueue.global(qos: .userInteractive).async {
            swallowed = tap.process(kind: kind, code: code, down: down)
            answered.signal()
        }
        return answered.wait(timeout: .now() + 1) == .success ? swallowed : nil
    }
    suite("Talk key tap") { test in
        test("it swallows the talk and replay triggers, and only those (any key while Settings records one)") {
            let t = TalkKeyTap.Triggers(talk: button6, replay: f13, recording: false)
            expect(TalkKeyTap.swallows(t, kind: .mouse, code: 5, down: true))
            expect(TalkKeyTap.swallows(t, kind: .mouse, code: 5, down: false))
            expect(TalkKeyTap.swallows(t, kind: .key, code: kVK_F13, down: true))
            expect(!TalkKeyTap.swallows(t, kind: .mouse, code: 3, down: true))       // Back still goes back
            expect(!TalkKeyTap.swallows(t, kind: .key, code: kVK_ANSI_A, down: true))  // typing still types
            let recording = TalkKeyTap.Triggers(talk: button6, replay: nil, recording: true)
            expect(TalkKeyTap.swallows(recording, kind: .key, code: kVK_ANSI_A, down: true))
            expect(TalkKeyTap.swallows(recording, kind: .mouse, code: 3, down: true))
            expect(!TalkKeyTap.swallows(recording, kind: .mouse, code: 3, down: false))
            expect(!TalkKeyTap.swallows(recording, kind: .mouse, code: 1, down: true))  // the right button is never a trigger
        }
        test("a press is answered while the main thread is busy, and reaches it afterwards, in order") {
            let tap = TalkKeyTap()
            tap.update(.init(talk: button6, replay: nil, recording: false))
            var got: [TalkKeyTap.Event] = []
            tap.deliver = { got.append($0) }
            let answered = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var swallowed: [Bool] = []
            DispatchQueue.global(qos: .userInteractive).async {  // macOS calling the tap, on its thread
                swallowed = [tap.process(kind: .mouse, code: 5, down: true), tap.process(kind: .mouse, code: 5, down: false),
                             tap.process(kind: .mouse, code: 3, down: true)]
                answered.signal()
            }
            // The main thread is blocked here, as if busy redrawing: the tap answers anyway.
            expect(answered.wait(timeout: .now() + 1) == .success, "the tap waited for the main thread")
            expectEqual(swallowed, [true, true, false])
            expect(waitFor(1) { got.count == 2 }, "the press never reached the main thread")
            expectEqual(got.map(\.down), [true, false])
        }
        test("the press and release reach PushToTalk: the talk button starts and ends a recording") {
            let settings = AppSettings.shared
            let saved = settings.talkTrigger
            settings.talkTrigger = button6
            defer { settings.talkTrigger = saved }
            let ptt = PushToTalk()
            var presses = 0, releases = 0
            ptt.onPress = { presses += 1 }
            ptt.onRelease = { releases += 1 }
            expectEqual(tapped(ptt.tapState, .mouse, 5, down: true), true)
            expect(waitFor(1) { presses == 1 }, "no press")
            expectEqual(tapped(ptt.tapState, .mouse, 5, down: false), true)
            expect(waitFor(1) { releases == 1 }, "no release")
            expectEqual(tapped(ptt.tapState, .key, kVK_ANSI_A, down: true), false)  // not the talk button
        }
    }
}
