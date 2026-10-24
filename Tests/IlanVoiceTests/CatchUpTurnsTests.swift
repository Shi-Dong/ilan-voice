import Foundation
@testable import IlanVoice

/// Turns in the audio a phone sends on coming back (its catch-up) keep their words.
@MainActor
func registerCatchUpTurnsTests() {
    func makeSession() -> (VoiceSession, RemoteMicrophone, ConversationStore, UUID) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let speaker = FakeSpeaker(), mic = RemoteMicrophone()
        speaker.isPlaying = false
        let session = VoiceSession(store: store, mcp: MCPManager(), input: mic, output: speaker,
                                   isRemote: true, target: { conv.id })
        session.conversationID = conv.id
        session.startConversation()
        session.handle(["type": "session.created"])
        session.handle(["type": "session.updated"])  // ready: audio goes to OpenAI (none here) and is counted
        return (session, mic, store, conv.id)
    }
    /// Loud enough to count as speech (a 200 Hz tone at about -12 dBFS).
    func speech(_ seconds: Double) -> Data {
        let samples = (0..<Int(seconds * PCM.sampleRate)).map { Int16(8000 * sin(Double($0) * 2 * .pi * 200 / PCM.sampleRate)) }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    func quiet(_ seconds: Double) -> Data { Data(count: Int(seconds * PCM.sampleRate) * 2) }
    /// All at once, in 0.1 s pieces, as PhoneClient hands over a catch-up.
    func deliver(_ mic: RemoteMicrophone, _ audio: Data) {
        var at = 0
        while at < audio.count {
            let end = min(audio.count, at + 4_800)
            mic.deliver(audio.subdata(in: at..<end))
            at = end
        }
        // The session takes each piece on the main queue, in order: once a
        // marker queued after them has run, all of them have been taken.
        var drained = false
        DispatchQueue.main.async { drained = true }
        expect(waitFor(1) { drained }, "the audio never reached the session")
    }
    /// One turn as OpenAI reports it, with its times from the start of the session's audio.
    func turn(_ session: VoiceSession, _ item: String, from start: Int, to end: Int) {
        session.handle(["type": "input_audio_buffer.speech_started", "audio_start_ms": start, "item_id": item])
        session.handle(["type": "input_audio_buffer.speech_stopped", "audio_end_ms": end, "item_id": item])
        session.handle(["type": "input_audio_buffer.committed", "item_id": item])
    }
    suite("Turns in a phone's catch-up") { test in
        test("turns OpenAI finds in a caught-up burst keep their own voice and audio; noise in it is still dropped") {
            let (session, mic, store, convID) = makeSession()
            var reports: [[String: Any]] = []
            session.onTurn = { reports.append($0) }
            // 12 s said while the phone was away, arriving in one go: speech at 3-5 s and 8-10 s.
            deliver(mic, quiet(3) + speech(2) + quiet(3) + speech(2) + quiet(2))
            // Only now does OpenAI report the turns in it.
            turn(session, "a", from: 2_800, to: 5_200)
            turn(session, "noise", from: 6_000, to: 6_500)
            turn(session, "b", from: 7_800, to: 10_200)
            expectEqual(reports.map { $0["outcome"] as? String }, ["kept", "dropped: too little voice", "kept"])
            expect(reports.allSatisfy { $0["fromCatchUp"] as? Bool == true }, "\(reports)")
            // Each turn counts only its own voice (2 s = 100 frames), not the other's.
            let a = reports.first?["voicedFrames"] as? Int ?? 0
            expect(a >= 95 && a <= 105, "turn a's voice: \(a)")
            for item in ["a", "b"] {
                let seconds = store.message(convID, item)?.audioSeconds ?? 0
                expect(abs(seconds - 2.4) < 0.05, "turn \(item)'s recording: \(seconds) s")
            }
            expect(store.message(convID, "noise") == nil)
            session.stopConversation()
        }
        test("a new OpenAI session counts its audio from zero again") {
            let (session, mic, store, convID) = makeSession()
            deliver(mic, quiet(2))
            session.handle(["type": "session.created"])  // reconnected: a new session
            deliver(mic, quiet(1) + speech(1.5) + quiet(0.5))
            turn(session, "u", from: 900, to: 2_600)
            let seconds = store.message(convID, "u")?.audioSeconds ?? 0
            expect(abs(seconds - 1.7) < 0.05, "the turn's recording: \(seconds) s")
            session.stopConversation()
        }
    }
}
