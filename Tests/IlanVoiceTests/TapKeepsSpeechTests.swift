import Combine
import Foundation
@testable import IlanVoice

/// A speaker that is "talking" until stopped, and counts what was done to it.
final class FakeSpeaker: VoiceOutput {
    var onDrained: (() -> Void)?
    var isPlaying = true
    var enqueuedFrames = 0
    var playedFrames = 0
    var stops = 0
    var enqueued = 0
    func enqueue(_ pcm: Data) { enqueued += 1 }
    func flush() {}
    func stop() { isPlaying = false; stops += 1 }
    var warmUps = 0
    /// How long the headphones take to wake up, as warmUp reports it.
    var wake: TimeInterval = 0
    func warmUp() -> TimeInterval { warmUps += 1; return wake }
}

/// A microphone that hands over 20 ms of loud audio every 20 ms while it runs.
final class FakeMic: VoiceInput {
    var onChunk: ((Data, Float) -> Void)?
    var deviceName: String? = "Test Microphone"
    var running = false
    /// False: the mic hears only quiet room noise.
    var loud = true
    /// 20 ms of audio delivered so far (each tick is one voiced frame when loud).
    var ticks = 0
    /// 20 ms frames delivered per tick: above 1 the mic runs faster than real
    /// time, so tests of long speech (0.8 s over Ilan) stay quick.
    var framesPerTick = 1
    var starts = 0
    /// How long the permission check takes (the first-run prompt is slow).
    var permissionDelay = 0.0
    func requestPermission() async -> Bool {
        if permissionDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(permissionDelay * 1e9)) }
        return true
    }
    func start() throws {
        starts += 1
        running = true
        tick()
    }
    func stop() { running = false }
    private func tick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.running else { return }
            self.ticks += 1
            // 20 ms of audio in phone-sized pieces (the iPhone page sends 64 samples at a time).
            let frame = self.loud ? Self.speech : Data(count: Self.speech.count)
            let audio = Data((0..<self.framesPerTick).flatMap { _ in frame })
            stride(from: 0, to: audio.count, by: Self.pieceBytes).forEach { offset in
                self.onChunk?(audio.subdata(in: offset..<min(offset + Self.pieceBytes, audio.count)), self.loud ? 0.3 : 0)
            }
            self.tick()
        }
    }
    /// 20 ms of a loud tone: counts as speech.
    static let pieceBytes = 60 * 2
    static let speech: Data = {
        let samples = (0..<480).map { i -> Int16 in i % 2 == 0 ? 8000 : -8000 }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }()
}

/// On the Mac, a tap of the talk key stops Ilan once no second tap follows; a
/// double tap (which opens the window) leaves Ilan alone; holding to talk
/// stops Ilan. Every corner case here is driven through a real VoiceSession.
@MainActor
func registerTapKeepsSpeechTests() {
    // The sessions here run on half-length tap timings (see makeSession), and
    // every wait is scaled the same way: the same sequences, in half the time.
    let speed = 0.5
    func s(_ seconds: Double) -> Double { seconds * speed }
    let window = s(VoiceSession.secondTapWindow)
    /// realTimings: the app's own timings, for a test that compares them with the pill's.
    func makeSession(remote: Bool = false, realTimings: Bool = false) -> (VoiceSession, FakeSpeaker, FakeMic) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let speaker = FakeSpeaker(), mic = FakeMic()
        let session = VoiceSession(store: store, mcp: MCPManager(), input: mic, output: speaker,
                                   isRemote: remote, target: { conv.id })
        session.conversationID = conv.id
        if !realTimings {
            session.holdForTalk = s(VoiceSession.minRecordingSeconds)
            session.tapStopDelay = window
        }
        return (session, speaker, mic)
    }
    func pause(_ seconds: Double) { waitFor(seconds) { false } }
    func press(_ session: VoiceSession) { session.pressToTalk(waitForDoubleTap: true) }
    func tap(_ session: VoiceSession) {
        press(session)
        session.releaseToTalk()
    }
    /// Two taps, then what the double-tap handler does.
    func doubleTap(_ session: VoiceSession) {
        tap(session)
        pause(s(0.1))
        tap(session)
        session.keepIlanGoing()
    }
    func outcomes(_ session: VoiceSession) -> (AnyCancellable, () -> [VoiceSession.PressOutcome]) {
        var seen: [VoiceSession.PressOutcome] = []
        let sub = session.pressEnded.sink { seen.append($0) }
        return (sub, { seen })
    }
    /// Ilan in the middle of a tool call that takes `seconds`, with no voice.
    func usingTool(_ session: VoiceSession, _ speaker: FakeSpeaker, seconds: Double) {
        speaker.isPlaying = false
        session.toolOverride = { _, _ in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            return "ok"
        }
        session.handle(["type": "response.done", "response": [
            "id": "r1", "output": [["type": "function_call", "name": "slow", "arguments": "{}", "call_id": "c1"]]]])
    }
    /// OpenAI starts the reply Ilan asked for after the tool, and its first audio arrives.
    func nextReplyStarts(_ session: VoiceSession) {
        session.handle(["type": "response.created", "response": ["id": "r2"]])
        session.handle(["type": "response.output_audio.delta", "response_id": "r2", "item_id": "i2",
                        "delta": Data(count: 4800).base64EncodedString()])
    }
    /// A two-second silent reply saved on disk, as replays and play buttons use.
    func savedReply(_ session: VoiceSession) -> (Message, URL) {
        let convID = session.store.selectedID!
        let url = session.store.audioURL(convID, "old.wav")
        try? PCM.wav(Data(count: Int(PCM.sampleRate) * 2 * 2)).write(to: url)
        var message = Message(id: "old", role: .assistant, text: "An earlier reply")
        message.audioFile = "old.wav"
        return (message, url)
    }

    suite("Talk-key taps while Ilan is busy") { test in
        // The three outcomes.
        test("a single tap leaves Ilan alone, then stops it once no second tap came") {
            let (session, speaker, _) = makeSession()
            let (sub, seen) = outcomes(session)
            let start = Date()
            tap(session)
            pause(s(0.2))
            expectEqual(speaker.stops, 0)  // a second tap may still come
            expect(waitFor(2) { speaker.stops == 1 }, "never stopped")
            expect(Date().timeIntervalSince(start) >= s(DoubleTapDetector().maxGap))
            expectEqual(seen(), [.stoppedSpeech])
            sub.cancel()
        }
        test("a double tap never stops Ilan") {
            let (session, speaker, _) = makeSession()
            let (sub, seen) = outcomes(session)
            doubleTap(session)
            pause(window + s(0.1))
            expectEqual(speaker.stops, 0)
            expect(speaker.isPlaying)
            expectEqual(seen(), [])
            sub.cancel()
        }
        test("holding the key stops Ilan once it is past a tap, and the pill shows at once") {
            let (session, speaker, mic) = makeSession(realTimings: true)  // compared with the pill's own wait
            press(session)
            pause(s(0.1))
            expectEqual(speaker.stops, 0)
            expect(waitFor(1) { session.phase == .recording }, "never went live")
            expectEqual(speaker.stops, 1)
            expect(mic.running)
            // Already recording (quietly) since the press: no extra wait for "Listening".
            expect(FloatingHUD.listeningWait(recordedFor: Date().timeIntervalSince(session.recordStart)) < 0.05)
            session.cancelRecording()
        }

        // How the press is recorded.
        test("a tap never shows as a recording") {
            let (session, _, mic) = makeSession()
            var phases: [VoiceSession.Phase] = []
            let sub = session.$phase.sink { phases.append($0) }
            press(session)
            pause(s(0.1))
            expect(mic.running)  // recording quietly, in case it is a hold
            session.releaseToTalk()
            expect(!mic.running)
            expect(session.recording.isEmpty)
            expect(!phases.contains(.recording))
            sub.cancel()
        }
        test("the first words of a held press are kept") {
            let (session, _, _) = makeSession()
            press(session)
            expect(waitFor(1) { session.phase == .recording })
            // Everything heard while the press was undecided is part of the recording.
            // (a loaded CI machine delivers fewer fake 20 ms chunks, so only require some)
            expect(PCM.seconds(session.recording) >= 0.04, "\(PCM.seconds(session.recording)) s")
            session.cancelRecording()
        }
        test("the pill waits the usual cutoff for a press that starts live") {
            expectEqual(FloatingHUD.listeningWait(recordedFor: 0), VoiceSession.minRecordingSeconds)
            expectEqual(FloatingHUD.listeningWait(recordedFor: 0.3), 0)
        }

        // Sequences of presses.
        test("a tap, then holding the second press: Ilan stops once that press is held") {
            let (session, speaker, _) = makeSession()
            let (sub, seen) = outcomes(session)
            tap(session)
            pause(s(0.12))
            press(session)
            pause(s(0.1))
            expectEqual(speaker.stops, 0)  // still undecided
            expect(waitFor(1) { session.phase == .recording })
            expectEqual(speaker.stops, 1)
            pause(s(0.15))  // now well past the first tap's window: its stop was called off
            expectEqual(session.phase, .recording)
            expectEqual(seen(), [])
            session.cancelRecording()
            sub.cancel()
        }
        test("a second tap the double-tap handler doesn't confirm still ends in one stop") {
            let (session, speaker, _) = makeSession()
            let (sub, seen) = outcomes(session)
            tap(session)
            pause(s(0.12))
            tap(session)  // e.g. too slow to count as a double tap
            pause(s(0.2))
            expectEqual(speaker.stops, 0)  // the second tap waits too
            expect(waitFor(2) { speaker.stops == 1 }, "never stopped")
            pause(s(0.1))
            expectEqual(speaker.stops, 1)
            expectEqual(seen(), [.stoppedSpeech])
            sub.cancel()
        }
        test("a late, slow second tap still counts: the first tap's stop is called off when it goes down") {
            let (session, speaker, _) = makeSession()
            tap(session)
            pause(s(0.3))  // the second tap starts late in the double-tap gap...
            press(session)
            pause(s(0.12))  // ...and is still down when the first tap's wait would end
            session.releaseToTalk()
            session.keepIlanGoing()
            pause(window + s(0.05))
            expectEqual(speaker.stops, 0)
        }
        test("a third tap after a double tap stops Ilan") {
            let (session, speaker, _) = makeSession()
            doubleTap(session)
            pause(s(0.1))
            tap(session)
            pause(s(0.15))
            expectEqual(speaker.stops, 0)
            expect(waitFor(2) { speaker.stops == 1 }, "never stopped")
        }

        // Ilan changes while the press is undecided.
        test("Ilan finishing during a tap's wait: nothing is stopped, the pill says nothing") {
            let (session, speaker, _) = makeSession()
            let (sub, seen) = outcomes(session)
            tap(session)
            speaker.isPlaying = false  // the reply ends on its own
            pause(window + s(0.15))
            expectEqual(speaker.stops, 0)
            expectEqual(seen(), [.discarded])
            sub.cancel()
        }
        test("a held press still goes live when Ilan finishes first") {
            let (session, speaker, _) = makeSession()
            press(session)
            speaker.isPlaying = false
            expect(waitFor(1) { session.phase == .recording })
            expectEqual(speaker.stops, 0)
            session.cancelRecording()
        }
        test("a double tap during a chain of tool calls lets the chain and the next reply carry on") {
            let (session, speaker, _) = makeSession()
            usingTool(session, speaker, seconds: s(0.1))
            doubleTap(session)
            pause(window + s(0.1))
            expectEqual(session.phase, .thinking)  // the tool's result went back
            nextReplyStarts(session)
            expectEqual(speaker.enqueued, 1)
            expectEqual(session.phase, .speaking)
        }
        test("a single tap during a chain of tool calls stops it") {
            let (session, speaker, _) = makeSession()
            usingTool(session, speaker, seconds: s(0.45))
            tap(session)
            pause(window + s(0.1))  // past the tool's end too
            expectEqual(session.phase, .offline)  // stopped; no API key in tests, so offline
        }
        test("a tap after a tool result went back cancels the reply asked for, once it starts") {
            let (session, speaker, _) = makeSession()
            usingTool(session, speaker, seconds: s(0.05))
            expect(waitFor(1) { session.phase == .thinking })
            tap(session)
            expect(waitFor(2) { session.phase != .thinking }, "never stopped")
            nextReplyStarts(session)
            expectEqual(speaker.enqueued, 0)  // never heard
            expect(session.phase != .speaking)
        }

        // Other things the user does around a press.
        test("a replay waits until the talk key is let go, then a tap's late stop doesn't cut it") {
            let (session, _, _) = makeSession()
            let (_, url) = savedReply(session)
            session.clips.markPlayed(id: "old", url: url)
            press(session)
            session.replayLast()
            expect(session.clips.playingID == nil)  // not while the key is down
            session.releaseToTalk()
            session.replayLast()
            pause(window + s(0.15))
            expectEqual(session.clips.playingID, "old")
            session.clips.stop()
        }
        test("a typed message waits until the talk key is let go, then a tap's late stop doesn't cancel it") {
            let (session, _, _) = makeSession()
            press(session)
            expect(!session.sendText("hello"))
            session.releaseToTalk()
            expect(session.sendText("hello"))
            pause(window + s(0.15))
            expectEqual(session.phase, .thinking)  // still waiting for Ilan's reply
        }
        test("playing a reply right after a tap isn't cut by the tap's late stop") {
            let (session, _, _) = makeSession()
            let (message, _) = savedReply(session)
            tap(session)
            session.play(message)
            pause(window + s(0.15))
            expectEqual(session.clips.playingID, "old")
            session.clips.stop()
        }
        test("with Ilan quiet, a tap does not wait") {
            let (session, speaker, _) = makeSession()
            speaker.isPlaying = false
            let (sub, seen) = outcomes(session)
            tap(session)
            pause(s(0.05))
            expectEqual(seen(), [.discarded])
            sub.cancel()
        }
        test("the orb and the iPhone have no double tap: they stop Ilan at once") {
            for remote in [false, true] {
                let (session, speaker, _) = makeSession(remote: remote)
                session.pressToTalk()
                expectEqual(speaker.stops, 1)
                session.releaseToTalk()
            }
        }

        // A slow microphone-permission check (the first-run prompt).
        test("a slow permission check starts the microphone only for its own press") {
            let (session, _, mic) = makeSession()
            mic.permissionDelay = s(0.3)
            tap(session)
            pause(s(0.1))
            press(session)  // held: talking
            expect(waitFor(1.5) { session.phase == .recording }, "never went live")
            pause(s(0.15))  // both checks are back
            expectEqual(mic.starts, 1)
            session.cancelRecording()
        }
        test("a held press let go before a slow permission check still says it stopped Ilan") {
            let (session, speaker, mic) = makeSession()
            mic.permissionDelay = s(0.4)
            let (sub, seen) = outcomes(session)
            press(session)
            expect(waitFor(1) { speaker.stops == 1 }, "never stopped")
            session.releaseToTalk()
            expect(waitFor(1) { !seen().isEmpty }, "nothing reported")
            expectEqual(seen(), [.stoppedSpeech])
            expectEqual(mic.starts, 0)
            sub.cancel()
        }
    }
}
