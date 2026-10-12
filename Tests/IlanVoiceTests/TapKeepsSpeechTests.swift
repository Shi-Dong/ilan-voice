import Combine
import Foundation
@testable import IlanVoice

/// A speaker that is "talking" until stopped, and logs what was done to it.
final class FakeSpeaker: VoiceOutput {
    var onDrained: (() -> Void)?
    var isPlaying = true
    var enqueuedFrames = 0
    var playedFrames = 0
    var stops = 0
    func enqueue(_ pcm: Data) {}
    func flush() {}
    func stop() { isPlaying = false; stops += 1 }
}

/// A microphone that hands over a little audio as soon as it starts.
final class FakeMic: VoiceInput {
    var onChunk: ((Data, Float) -> Void)?
    var running = false
    func requestPermission() async -> Bool { true }
    func start() throws {
        running = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [self] in
            if running { onChunk?(Data(count: 960), 0.1) }
        }
    }
    func stop() { running = false }
}

/// A single tap of the talk key stops Ilan once no second tap follows; a
/// double tap (which opens the window) leaves Ilan alone; holding to talk
/// stops Ilan.
@MainActor
func registerTapKeepsSpeechTests() {
    func makeSession(remote: Bool = false) -> (VoiceSession, FakeSpeaker, FakeMic) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let speaker = FakeSpeaker(), mic = FakeMic()
        let session = VoiceSession(store: store, mcp: MCPManager(), input: mic, output: speaker,
                                   isRemote: remote, target: { conv.id })
        session.conversationID = conv.id
        return (session, speaker, mic)
    }
    func pause(_ seconds: Double) { waitFor(seconds) { false } }
    func outcomes(_ session: VoiceSession) -> (AnyCancellable, () -> [VoiceSession.PressOutcome]) {
        var seen: [VoiceSession.PressOutcome] = []
        let sub = session.pressEnded.sink { seen.append($0) }
        return (sub, { seen })
    }
    /// Ilan in the middle of a tool call that takes `seconds`.
    @MainActor func usingTool(_ session: VoiceSession, _ speaker: FakeSpeaker, seconds: Double) {
        speaker.isPlaying = false  // silent tool use, no voice
        session.toolOverride = { _, _ in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            return "ok"
        }
        session.handle(["type": "response.done", "response": [
            "id": "r1", "output": [["type": "function_call", "name": "slow", "arguments": "{}", "call_id": "c1"]]]])
    }

    suite("Talk-key taps while Ilan is busy") { test in
        test("a single tap leaves Ilan alone, then stops it once no second tap came") {
            let (session, speaker, _) = makeSession()
            let (sub, seen) = outcomes(session)
            let start = Date()
            session.pressToTalk()
            session.releaseToTalk()
            pause(0.2)
            expectEqual(speaker.stops, 0)  // a second tap may still come
            expect(waitFor(2) { speaker.stops == 1 }, "never stopped")
            expect(Date().timeIntervalSince(start) >= DoubleTapDetector().maxGap)
            expectEqual(seen(), [.stoppedSpeech])
            sub.cancel()
        }
        test("a double tap never stops Ilan") {
            let (session, speaker, _) = makeSession()
            let (sub, seen) = outcomes(session)
            session.pressToTalk()
            session.releaseToTalk()
            pause(0.12)
            session.pressToTalk()
            session.releaseToTalk()
            session.keepIlanGoing()  // what the double-tap handler does
            pause(VoiceSession.secondTapWindow + 0.2)
            expectEqual(speaker.stops, 0)
            expect(speaker.isPlaying)
            expectEqual(seen(), [])
            sub.cancel()
        }
        test("a tap never shows as a recording") {
            let (session, _, mic) = makeSession()
            var phases: [VoiceSession.Phase] = []
            let sub = session.$phase.sink { phases.append($0) }
            session.pressToTalk()
            pause(0.1)
            expect(mic.running)  // recording quietly, in case it is a hold
            session.releaseToTalk()
            expect(!mic.running)
            expect(!phases.contains(.recording))
            sub.cancel()
        }
        test("holding the key to talk stops Ilan and starts recording") {
            let (session, speaker, mic) = makeSession()
            session.pressToTalk()
            pause(0.1)
            expectEqual(speaker.stops, 0)
            expect(waitFor(1) { session.phase == .recording }, "never went live")
            expectEqual(speaker.stops, 1)
            expect(mic.running)
            session.releaseToTalk()
            pause(0.3)
            expectEqual(speaker.stops, 1)
        }
        test("a double tap during a chain of tool calls lets the chain carry on") {
            let (session, speaker, _) = makeSession()
            usingTool(session, speaker, seconds: 0.1)
            session.pressToTalk()
            pause(0.15)  // the tool finishes while the first tap is down
            session.releaseToTalk()
            pause(0.2)
            session.pressToTalk()
            session.releaseToTalk()
            session.keepIlanGoing()
            pause(VoiceSession.secondTapWindow + 0.2)
            // The tool's result went back and Ilan is thinking about it.
            expectEqual(session.phase, .thinking)
        }
        test("a single tap during a chain of tool calls stops it") {
            let (session, speaker, _) = makeSession()
            usingTool(session, speaker, seconds: 0.6)
            session.pressToTalk()
            session.releaseToTalk()
            pause(VoiceSession.secondTapWindow + 0.5)  // past the tool's end too
            expectEqual(session.phase, .offline)  // stopped; no API key in tests, so offline
        }
        test("with Ilan quiet, a tap does not wait") {
            let (session, speaker, _) = makeSession()
            speaker.isPlaying = false
            let (sub, seen) = outcomes(session)
            session.pressToTalk()
            session.releaseToTalk()
            pause(0.05)
            expectEqual(seen(), [.discarded])
            sub.cancel()
        }
        test("on the iPhone a tap stops Ilan at once") {
            let (session, speaker, _) = makeSession(remote: true)
            session.pressToTalk()
            expectEqual(speaker.stops, 1)
            session.releaseToTalk()
        }
    }
}
