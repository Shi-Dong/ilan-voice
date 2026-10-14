import Foundation
@testable import IlanVoice

/// The iPhone's hands-free conversation mode: tap to start, tap to end; OpenAI
/// decides when each turn is over.
@MainActor
func registerConversationModeTests() {
    func makeSession() -> (VoiceSession, FakeSpeaker, FakeMic) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let speaker = FakeSpeaker(), mic = FakeMic()
        speaker.isPlaying = false
        let session = VoiceSession(store: store, mcp: MCPManager(), input: mic, output: speaker,
                                   isRemote: true, target: { conv.id })
        session.conversationID = conv.id
        return (session, speaker, mic)
    }
    suite("Conversation mode") { test in
        test("turns are detected by meaning, and OpenAI answers by itself") {
            expectEqual(VoiceSession.semanticTurns["type"] as? String, "semantic_vad")
            // The app interrupts and asks for replies itself, after checking the turn was speech.
            expectEqual(VoiceSession.semanticTurns["create_response"] as? Bool, false)
            expectEqual(VoiceSession.semanticTurns["interrupt_response"] as? Bool, false)
        }
        test("starting opens the microphone and listens; stopping closes it") {
            let (session, _, mic) = makeSession()
            session.startConversation()
            expect(session.conversationActive)
            expect(mic.running)
            expectEqual(session.phase, .recording)
            session.stopConversation()
            expect(!session.conversationActive && !mic.running)
            expect(session.phase != .recording)
        }
        test("a turn: speech ends → thinking → reply → listening again (not 'ready')") {
            let (session, _, _) = makeSession()
            session.startConversation()
            session.handle(["type": "input_audio_buffer.speech_started"])
            expect(waitFor(3) { session.turnIsSpeech }, "voice never counted")  // 0.2 s of voice
            expectEqual(session.phase, .recording)
            session.handle(["type": "input_audio_buffer.speech_stopped"])
            expectEqual(session.phase, .thinking)
            session.handle(["type": "response.created", "response": ["id": "r1"]])
            session.handle(["type": "response.done", "response": ["id": "r1", "output": []]])
            expectEqual(session.phase, .recording)
            session.stopConversation()
        }
        test("speaking over Ilan stops its reply") {
            let (session, speaker, _) = makeSession()
            session.startConversation()
            session.handle(["type": "response.created", "response": ["id": "r1"]])
            speaker.isPlaying = true
            session.handle(["type": "response.output_audio.delta", "response_id": "r1", "item_id": "i1",
                            "delta": Data(count: 4800).base64EncodedString()])
            expectEqual(session.phase, .speaking)
            let stopsBefore = speaker.stops
            session.handle(["type": "input_audio_buffer.speech_started"])
            expect(waitFor(1) { speaker.stops > stopsBefore }, "reply not stopped")
            expectEqual(session.phase, .recording)
            session.stopConversation()
        }
        test("outside a conversation, speech events change nothing (push to talk)") {
            let (session, _, _) = makeSession()
            let before = session.phase
            session.handle(["type": "input_audio_buffer.speech_started"])
            session.handle(["type": "input_audio_buffer.speech_stopped"])
            expectEqual(session.phase, before)
        }
    }
}

/// Conversation turns are transcribed as they happen, like push-to-talk turns.
@MainActor
func registerConversationTranscriptTests() {
    func makeSession() -> (VoiceSession, ConversationStore, UUID) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let speaker = FakeSpeaker()
        speaker.isPlaying = false
        let session = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: speaker,
                                   isRemote: true, target: { conv.id })
        session.conversationID = conv.id
        return (session, store, conv.id)
    }
    /// One spoken turn, as OpenAI reports it.
    func speak(_ session: VoiceSession, item: String) {
        session.handle(["type": "input_audio_buffer.speech_started"])
        expect(waitFor(3) { session.turnIsSpeech }, "voice never counted")
        session.handle(["type": "input_audio_buffer.speech_stopped"])
        session.handle(["type": "input_audio_buffer.committed", "item_id": item])
    }
    suite("Conversation transcripts") { test in
        test("each turn shows its transcript as soon as OpenAI has it, mid-conversation") {
            let (session, store, convID) = makeSession()
            session.startConversation()
            speak(session, item: "u1")
            let m = store.message(convID, "u1")
            expect(m?.audioFile != nil && (m?.audioSeconds ?? 0) > 0.1, "turn recording not saved")
            session.handle(["type": "conversation.item.input_audio_transcription.delta", "item_id": "u1", "delta": "What is "])
            expectEqual(store.message(convID, "u1")?.text, "What is ")
            session.handle(["type": "conversation.item.input_audio_transcription.completed", "item_id": "u1",
                            "transcript": "What is the weather?"])
            expectEqual(store.message(convID, "u1")?.text, "What is the weather?")
            expect(session.conversationActive)  // no need to end the conversation first
            session.stopConversation()
        }
        test("Luna's repair runs once Ilan has answered the turn, still mid-conversation") {
            let (session, store, convID) = makeSession()
            session.startConversation()
            speak(session, item: "u1")
            session.handle(["type": "conversation.item.input_audio_transcription.completed", "item_id": "u1",
                            "transcript": "What is the weather?"])
            expect(store.message(convID, "u1")?.awaitingCorrection == true)  // grey: Ilan is still answering
            session.handle(["type": "response.created", "response": ["id": "r1"]])
            session.handle(["type": "response.output_item.added", "item": ["id": "a1", "type": "message"]])
            session.handle(["type": "response.output_audio_transcript.delta", "item_id": "a1", "delta": "Sunny."])
            session.handle(["type": "response.output_item.done", "item": ["id": "a1", "type": "message"]])
            session.handle(["type": "response.done", "response": ["id": "r1", "output": []]])
            // No API key in tests: Luna gives nothing back, and the turn turns final as heard.
            expect(waitFor(2) { store.message(convID, "u1")?.awaitingCorrection == nil }, "never final")
            expectEqual(store.message(convID, "u1")?.text, "What is the weather?")
            expect(session.conversationActive)
            session.stopConversation()
        }
        test("a new turn finalises the one before, as in push to talk") {
            let (session, store, convID) = makeSession()
            session.startConversation()
            speak(session, item: "u1")
            session.handle(["type": "conversation.item.input_audio_transcription.completed", "item_id": "u1",
                            "transcript": "First."])
            speak(session, item: "u2")
            expect(store.message(convID, "u1")?.awaitingCorrection == nil)
            session.stopConversation()
        }
    }
}

/// While an iPhone conversation is live, the Mac can read it but not talk or type in it.
@MainActor
func registerLiveOnPhoneTests() {
    suite("Live on iPhone") { test in
        test("the Mac can't talk or type in a conversation live on the iPhone, until it ends") {
            let store = ConversationStore()
            let conv = store.newConversation()
            let other = Conversation()
            let phoneSpeaker = FakeSpeaker(), macSpeaker = FakeSpeaker()
            phoneSpeaker.isPlaying = false; macSpeaker.isPlaying = false
            let phone = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: phoneSpeaker,
                                     isRemote: true, target: { conv.id })
            var macTarget = conv.id
            let mac = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: macSpeaker,
                                   target: { macTarget })
            mac.conversationID = conv.id
            phone.startConversation()
            expect(store.liveOnPhone.contains(conv.id))
            expect(mac.targetLiveOnPhone)
            mac.pressToTalk()
            expect(waitFor(0.3) { mac.phase == .recording } == false, "Mac recorded into a live conversation")
            expectEqual(mac.errorMessage, VoiceSession.liveOnPhoneMessage)
            expect(!mac.sendText("hello"))
            // Other conversations are unaffected.
            macTarget = other.id
            expect(!mac.targetLiveOnPhone)
            macTarget = conv.id
            phone.stopConversation()
            expect(store.liveOnPhone.isEmpty)
            expect(!mac.targetLiveOnPhone)
        }
        test("the iPhone's own session is never locked out") {
            let store = ConversationStore()
            let conv = store.newConversation()
            let phone = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: FakeSpeaker(),
                                     isRemote: true, target: { conv.id })
            phone.startConversation()
            expect(!phone.targetLiveOnPhone)
            phone.stopConversation()
        }
    }
}

/// What happens when things go away in the middle of an iPhone conversation.
@MainActor
func registerConversationEdgeTests() {
    func makeSession() -> (VoiceSession, FakeSpeaker, FakeMic, ConversationStore, UUID) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let speaker = FakeSpeaker(), mic = FakeMic()
        speaker.isPlaying = false
        let session = VoiceSession(store: store, mcp: MCPManager(), input: mic, output: speaker,
                                   isRemote: true, target: { conv.id })
        session.conversationID = conv.id
        return (session, speaker, mic, store, conv.id)
    }
    suite("Conversation edge cases") { test in
        test("a phone that goes silent (gone without closing) ends the conversation and unlocks the Mac") {
            let (session, _, mic, store, convID) = makeSession()
            session.conversationSilenceLimit = 0.5
            session.startConversation()
            expect(store.liveOnPhone.contains(convID))
            mic.running = false  // no more audio arrives
            expect(waitFor(2) { !session.conversationActive },
                   "conversation never ended")
            expect(!store.liveOnPhone.contains(convID))
            expect(session.errorMessage?.contains("Lost the iPhone") == true)
        }
        test("a phone still sending audio is never ended for silence") {
            let (session, _, _, _, _) = makeSession()
            session.conversationSilenceLimit = 0.25
            session.startConversation()
            waitFor(0.5) { false }
            expect(session.conversationActive)
            session.stopConversation()
        }
    }
}

@MainActor
func registerConversationStopTests() {
    suite("Ending a conversation") { test in
        test("ending while Ilan is talking silences it at once") {
            let store = ConversationStore()
            let conv = store.newConversation()
            let speaker = FakeSpeaker()
            speaker.isPlaying = false
            let session = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: speaker,
                                       isRemote: true, target: { conv.id })
            session.conversationID = conv.id
            session.startConversation()
            session.handle(["type": "response.created", "response": ["id": "r1"]])
            speaker.isPlaying = true
            session.handle(["type": "response.output_audio.delta", "response_id": "r1", "item_id": "i1",
                            "delta": Data(count: 4800).base64EncodedString()])
            let before = speaker.stops
            session.stopConversation()
            expect(speaker.stops > before, "Ilan kept talking")
            // Any more of that reply is dropped, not played.
            let enqueued = speaker.enqueued
            session.handle(["type": "response.output_audio.delta", "response_id": "r1", "item_id": "i1",
                            "delta": Data(count: 4800).base64EncodedString()])
            expectEqual(speaker.enqueued, enqueued)
        }
    }
}

/// Noise (room sound, Ilan's own voice leaking into the mic) never counts as a turn.
@MainActor
func registerConversationNoiseTests() {
    func makeSession() -> (VoiceSession, FakeSpeaker, FakeMic, ConversationStore, UUID) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let speaker = FakeSpeaker(), mic = FakeMic()
        speaker.isPlaying = false
        let session = VoiceSession(store: store, mcp: MCPManager(), input: mic, output: speaker,
                                   isRemote: true, target: { conv.id })
        session.conversationID = conv.id
        return (session, speaker, mic, store, conv.id)
    }
    suite("Conversation noise") { test in
        test("a noise turn doesn't cut Ilan off, gets no reply and leaves no message") {
            let (session, speaker, mic, store, convID) = makeSession()
            mic.loud = false
            session.startConversation()
            session.handle(["type": "response.created", "response": ["id": "r1"]])
            speaker.isPlaying = true
            session.handle(["type": "response.output_audio.delta", "response_id": "r1", "item_id": "i1",
                            "delta": Data(count: 4800).base64EncodedString()])
            let stops = speaker.stops
            session.handle(["type": "input_audio_buffer.speech_started"])
            waitFor(0.3) { false }
            session.handle(["type": "input_audio_buffer.speech_stopped"])
            session.handle(["type": "input_audio_buffer.committed", "item_id": "n1"])
            expectEqual(speaker.stops, stops)          // Ilan kept talking
            expectEqual(session.phase, .speaking)
            expect(store.message(convID, "n1") == nil) // no "(no words heard)" turn
            // Ilan's reply keeps playing.
            let enqueued = speaker.enqueued
            session.handle(["type": "response.output_audio.delta", "response_id": "r1", "item_id": "i1",
                            "delta": Data(count: 4800).base64EncodedString()])
            expectEqual(speaker.enqueued, enqueued + 1)
            session.stopConversation()
        }
        test("real speech over Ilan still interrupts, and becomes a turn") {
            let (session, speaker, _, store, convID) = makeSession()
            session.startConversation()
            session.handle(["type": "response.created", "response": ["id": "r1"]])
            speaker.isPlaying = true
            session.handle(["type": "response.output_audio.delta", "response_id": "r1", "item_id": "i1",
                            "delta": Data(count: 4800).base64EncodedString()])
            let stops = speaker.stops
            session.handle(["type": "input_audio_buffer.speech_started"])
            expect(waitFor(1) { speaker.stops > stops }, "not interrupted")
            session.handle(["type": "input_audio_buffer.speech_stopped"])
            session.handle(["type": "input_audio_buffer.committed", "item_id": "u1"])
            expect(store.message(convID, "u1") != nil)
            expectEqual(session.phase, .thinking)
            session.stopConversation()
        }
        test("a quick backchannel (under 0.2 s of voice) isn't a turn") {
            expectEqual(VoiceSession.minTurnVoicedFrames, 10)
            let yeah = Data((0..<(7 * 480)).flatMap { i -> [UInt8] in
                let v = Int16(i % 2 == 0 ? 3000 : -3000); return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] })
            expectEqual(PCM.voicedFrames(yeah), 7)
            expect(PCM.voicedFrames(yeah) < VoiceSession.minTurnVoicedFrames)
        }
    }
}

/// Ilan's own voice leaking back into the iPhone's mic never interrupts it.
@MainActor
func registerConversationEchoTests() {
    func makeSession() -> (VoiceSession, FakeSpeaker, FakeMic, ConversationStore, UUID) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let speaker = FakeSpeaker(), mic = FakeMic()
        speaker.isPlaying = false
        let session = VoiceSession(store: store, mcp: MCPManager(), input: mic, output: speaker,
                                   isRemote: true, target: { conv.id })
        session.conversationID = conv.id
        return (session, speaker, mic, store, conv.id)
    }
    /// Ilan is talking on the phone.
    func ilanTalks(_ session: VoiceSession, _ speaker: FakeSpeaker) {
        session.handle(["type": "response.created", "response": ["id": "r1"]])
        speaker.isPlaying = true
        session.handle(["type": "response.output_audio.delta", "response_id": "r1", "item_id": "i1",
                        "delta": Data(count: 4800).base64EncodedString()])
    }
    /// A short burst of voice (about 0.3 s, like an echo of "Let me"), then quiet.
    func burst(_ session: VoiceSession, _ mic: FakeMic, item: String) {
        mic.loud = false
        session.handle(["type": "input_audio_buffer.speech_started"])
        mic.loud = true
        waitFor(0.3) { false }
        mic.loud = false
        waitFor(0.05) { false }
        session.handle(["type": "input_audio_buffer.speech_stopped"])
        session.handle(["type": "input_audio_buffer.committed", "item_id": item])
    }
    suite("Conversation echo") { test in
        test("an echo-length burst while Ilan talks neither interrupts it nor becomes a turn") {
            let (session, speaker, mic, store, convID) = makeSession()
            session.startConversation()
            ilanTalks(session, speaker)
            let stops = speaker.stops
            burst(session, mic, item: "e1")
            expectEqual(speaker.stops, stops)
            expectEqual(session.phase, .speaking)
            expect(store.message(convID, "e1") == nil)
            session.stopConversation()
        }
        test("the same short burst while Ilan is quiet is a turn") {
            let (session, _, mic, store, convID) = makeSession()
            session.startConversation()
            burst(session, mic, item: "u1")
            expect(store.message(convID, "u1") != nil)
            session.stopConversation()
        }
        test("talking over Ilan for real still interrupts it") {
            let (session, speaker, _, store, convID) = makeSession()
            session.startConversation()
            ilanTalks(session, speaker)
            let stops = speaker.stops
            session.handle(["type": "input_audio_buffer.speech_started"])
            expect(waitFor(3) { speaker.stops > stops }, "not interrupted")
            session.handle(["type": "input_audio_buffer.speech_stopped"])
            session.handle(["type": "input_audio_buffer.committed", "item_id": "u1"])
            expect(store.message(convID, "u1") != nil)
            session.stopConversation()
        }
        test("the bar while Ilan talks sits above the echo bursts and below real speech") {
            expect(VoiceSession.minBargeInVoicedFrames > 15)  // the two echo turns: 13 and 15
            expect(VoiceSession.minBargeInVoicedFrames <= 30) // real speech: about 30 a second
        }
    }
}
