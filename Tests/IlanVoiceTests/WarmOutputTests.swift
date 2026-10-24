import Foundation
@testable import IlanVoice

/// A reply's first word isn't lost while headphones wake up.
@MainActor
func registerWarmOutputTests() {
    suite("Speakers wake up before a reply") { test in
        test("a reply finding the speakers off starts with silence for their wake-up; once they are awake, none") {
            var warmth = OutputWarmth()
            let now = Date()
            expectEqual(warmth.leadSilence(at: now), OutputWarmth.wakeSeconds)  // off: all of it
            warmth.switchedOn(at: now)
            expectEqual(warmth.leadSilence(at: now), OutputWarmth.wakeSeconds)  // switched on just as it plays
            expect(abs(warmth.leadSilence(at: now.addingTimeInterval(0.1)) - (OutputWarmth.wakeSeconds - 0.1)) < 0.001)
            expectEqual(warmth.leadSilence(at: now.addingTimeInterval(1.2)), 0)  // woken early, a second before
            warmth.switchedOff()
            expectEqual(warmth.leadSilence(at: now.addingTimeInterval(5)), OutputWarmth.wakeSeconds)
            expect(OutputWarmth.wakeSeconds >= 0.25 && OutputWarmth.wakeSeconds <= 0.5)
            expect(OutputWarmth.idleSeconds >= 30, "headphones would power down between replies")
        }
        test("typing a message wakes the speakers at once, before the reply is even asked for") {
            let store = ConversationStore()
            let conv = store.newConversation()
            let speaker = FakeSpeaker()
            speaker.isPlaying = false
            let session = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: speaker, target: { conv.id })
            _ = session.sendText("What's the weather?")  // no API key here, so nothing is sent
            expectEqual(speaker.warmUps, 1)
            expectEqual(session.sendText("   "), false)  // an empty message wakes nothing
            expectEqual(speaker.warmUps, 1)
        }
        test("every reply OpenAI starts wakes the speakers, also one after a tool call") {
            let store = ConversationStore()
            let conv = store.newConversation()
            let speaker = FakeSpeaker()
            speaker.isPlaying = false
            let session = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: speaker, target: { conv.id })
            session.conversationID = conv.id
            session.handle(["type": "response.created", "response": ["id": "r1"]])
            session.handle(["type": "response.created", "response": ["id": "r2"]])
            expectEqual(speaker.warmUps, 2)
        }
    }
}
