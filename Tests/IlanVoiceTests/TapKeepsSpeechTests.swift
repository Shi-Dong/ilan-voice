import Combine
import Foundation
@testable import IlanVoice

/// A speaker that is "talking" until stopped, and logs what was done to it.
final class FakeSpeaker: VoiceOutput {
    var onDrained: (() -> Void)?
    var isPlaying = true
    var enqueuedFrames = 0
    var playedFrames = 0
    var log: [String] = []
    func enqueue(_ pcm: Data) {}
    func flush() {}
    func stop() { isPlaying = false; log.append("stop") }
    func pause() { log.append("pause") }
    func resume() { log.append("resume") }
}

final class FakeMic: VoiceInput {
    var onChunk: ((Data, Float) -> Void)?
    func requestPermission() async -> Bool { true }
    func start() throws {}
    func stop() {}
}

/// A single tap of the talk key stops Ilan; a double tap (which opens the
/// window) lets Ilan carry on; holding to talk stops Ilan.
@MainActor
func registerTapKeepsSpeechTests() {
    func makeSession() -> (VoiceSession, FakeSpeaker) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let speaker = FakeSpeaker()
        let session = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: speaker, target: { conv.id })
        return (session, speaker)
    }
    func pause(_ seconds: Double) { waitFor(seconds) { false } }

    suite("Talk-key taps while Ilan speaks") { test in
        test("a single tap silences Ilan at once and stops it after the double-tap window") {
            let (session, speaker) = makeSession()
            var outcomes: [VoiceSession.PressOutcome] = []
            let sub = session.pressEnded.sink { outcomes.append($0) }
            let start = Date()
            session.pressToTalk()
            expectEqual(speaker.log, ["pause"])
            session.releaseToTalk()
            pause(0.1)
            expectEqual(speaker.log, ["pause"])  // not decided yet: a second tap may follow
            expect(waitFor(2) { speaker.log.contains("stop") }, "never stopped")
            expect(Date().timeIntervalSince(start) >= DoubleTapDetector().maxGap)
            expect(!session.speechHeld)
            expectEqual(outcomes, [.stoppedSpeech])
            sub.cancel()
        }
        test("a double tap resumes Ilan and never stops it") {
            let (session, speaker) = makeSession()
            session.pressToTalk()
            session.releaseToTalk()
            pause(0.12)
            session.pressToTalk()
            session.releaseToTalk()
            session.resumeHeldSpeech()  // what the double-tap handler does
            pause(VoiceSession.doubleTapWindow + 0.2)
            expectEqual(speaker.log, ["pause", "resume"])
            expect(!session.speechHeld)
        }
        test("holding the key to talk stops Ilan once it is a real press") {
            let (session, speaker) = makeSession()
            session.pressToTalk()
            pause(0.1)
            expectEqual(speaker.log, ["pause"])
            expect(waitFor(1) { speaker.log.contains("stop") }, "never stopped")
            session.releaseToTalk()
            pause(0.3)
            expectEqual(speaker.log.filter { $0 == "stop" }.count, 1)
        }
        test("a resume after the stop changes nothing") {
            let (session, speaker) = makeSession()
            session.pressToTalk()
            session.releaseToTalk()
            expect(waitFor(2) { speaker.log.contains("stop") })
            session.resumeHeldSpeech()
            expect(!speaker.log.contains("resume"))
        }
        /// Ilan in the middle of a tool call that takes `seconds`; logs whether
        /// the tool finished while the tap's brief recording was on screen.
        @MainActor func sessionUsingTool(_ seconds: Double) -> (VoiceSession, FakeSpeaker, () -> Bool) {
            let (session, speaker) = makeSession()
            speaker.isPlaying = false  // silent tool use, no voice
            session.conversationID = session.store.selectedID
            var finishedDuringTap = false
            session.toolOverride = { [weak session] _, _ in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                finishedDuringTap = session?.phase == .recording
                return "ok"
            }
            session.handle(["type": "response.done", "response": [
                "id": "r1", "output": [["type": "function_call", "name": "slow", "arguments": "{}", "call_id": "c1"]]]])
            expectEqual(session.phase, .working)
            return (session, speaker, { finishedDuringTap })
        }
        test("a double tap during a chain of tool calls lets the chain carry on") {
            let (session, speaker, finishedDuringTap) = sessionUsingTool(0.1)
            session.pressToTalk()
            pause(0.15)  // the tool finishes while the first tap is down
            session.releaseToTalk()
            pause(0.2)
            session.pressToTalk()
            session.releaseToTalk()
            session.resumeHeldSpeech()
            pause(VoiceSession.doubleTapWindow + 0.2)
            expect(finishedDuringTap(), "the tool should finish during the tap (test timing)")
            // The tool's result went back and Ilan is thinking about it.
            expectEqual(session.phase, .thinking)
            expect(!speaker.log.contains("stop"))
        }
        test("a single tap during a chain of tool calls still stops it") {
            let (session, speaker, _) = sessionUsingTool(0.1)
            session.pressToTalk()
            pause(0.15)
            session.releaseToTalk()
            expect(waitFor(2) { speaker.log.contains("stop") }, "never stopped")
            pause(0.1)
            expectEqual(session.phase, .offline)  // no API key in tests: offline, not ready
        }
        test("with Ilan quiet, a tap pauses nothing") {
            let (session, speaker) = makeSession()
            speaker.isPlaying = false
            session.pressToTalk()
            session.releaseToTalk()
            pause(0.1)
            expect(!speaker.log.contains("pause") && !session.speechHeld)
        }
    }
}
