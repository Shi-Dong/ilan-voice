import Carbon.HIToolbox
import Foundation
@testable import IlanVoice

/// The optional global key that replays Ilan's last reply.
@MainActor
func registerReplayHotkeyTests() {
    let rightOption = TalkTrigger.rightOption
    let f13 = TalkTrigger.key(keyCode: kVK_F13, characters: nil)
    let back = TalkTrigger.mouse(button: 3)!

    suite("Replay hotkey") { test in
        test("recording a replay key keeps the talk key") {
            let r = PushToTalk.assign(f13, to: .replay, talk: rightOption, replay: nil)
            expectEqual(r.talk, rightOption)
            expectEqual(r.replay, f13)
        }
        test("the talk key can't also be the replay key") {
            let r = PushToTalk.assign(rightOption, to: .replay, talk: rightOption, replay: f13)
            expectEqual(r.talk, rightOption)
            expectEqual(r.replay, f13)  // unchanged
        }
        test("taking the replay key for talking clears replay") {
            let r = PushToTalk.assign(back, to: .talk, talk: rightOption, replay: back)
            expectEqual(r.talk, back)
            expect(r.replay == nil)
            let kept = PushToTalk.assign(back, to: .talk, talk: rightOption, replay: f13)
            expectEqual(kept.replay, f13)
        }
        test("events match only the right kind and code") {
            expect(PushToTalk.matches(f13, kind: .key, code: kVK_F13))
            expect(!PushToTalk.matches(f13, kind: .mouse, code: kVK_F13))
            expect(!PushToTalk.matches(f13, kind: .key, code: kVK_F14))
            expect(!PushToTalk.matches(nil, kind: .key, code: kVK_F13))
            expect(PushToTalk.matches(back, kind: .mouse, code: 3))
        }
        test("the replay key is saved and restored") {
            let data = try JSONEncoder().encode(Optional(back))
            expectEqual(try JSONDecoder().decode(TalkTrigger?.self, from: data), back)
        }
    }
}
