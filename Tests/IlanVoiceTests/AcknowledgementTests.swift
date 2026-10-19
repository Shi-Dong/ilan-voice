import Foundation
@testable import IlanVoice

/// No reply to a bare acknowledgement ("Hmm.", "Good.", "I see.") in a conversation.
@MainActor
func registerAcknowledgementTests() {
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
    /// A turn with `frames` voiced frames (default 20: a quick "Good."), as OpenAI reports it.
    func say(_ session: VoiceSession, _ mic: FakeMic, item: String, frames: Int = 20) {
        mic.loud = false
        session.handle(["type": "input_audio_buffer.speech_started"])
        let start = mic.ticks
        mic.framesPerTick = max(4, frames / 5)  // the turn in about five 20 ms ticks
        mic.loud = true
        expect(waitFor(5) { (mic.ticks - start) * mic.framesPerTick >= frames }, "mic stalled")
        mic.loud = false
        waitFor(0.05) { false }
        session.handle(["type": "input_audio_buffer.speech_stopped"])
        session.handle(["type": "input_audio_buffer.committed", "item_id": item])
    }
    func transcript(_ session: VoiceSession, _ item: String, _ text: String) {
        session.handle(["type": "conversation.item.input_audio_transcription.completed", "item_id": item, "transcript": text])
    }
    func ilanSaid(_ store: ConversationStore, _ convID: UUID, _ text: String) {
        store.update(convID) { $0.messages.append(Message(id: UUID().uuidString, role: .assistant, text: text)) }
    }
    suite("No reply to a bare acknowledgement") { test in
        test("these are acknowledgements; questions and anything more are not") {
            for ack in ["Hmm.", "Mm-hmm.", "Good.", "Good, good.", "Okay.", "OK, I see.", "I see.", "Got it, thanks!",
                        "Yeah, that makes sense.", "Right, right.", "Great", "嗯。", "好的好的"] {
                expect(VoiceSession.isAcknowledgement(ack), "\(ack) should be an acknowledgement")
            }
            for words in ["", "Good morning.", "Okay, what's next?", "I see a car.", "Hmm, why?", "Right?", "Okay?",
                          "Yes.", "No.", "Stop.", "Tell me more.", "Good, and you?", "好的，然后呢？"] {
                expect(!VoiceSession.isAcknowledgement(words), "\(words) is not just an acknowledgement")
            }
        }
        test("a short turn waits for its transcript; just \"Hmm.\" gets no reply, and is still kept") {
            let (session, _, mic, store, convID) = makeSession()
            var reports: [[String: Any]] = []
            session.onTurn = { reports.append($0) }
            session.startConversation()
            say(session, mic, item: "u1")
            expectEqual(session.replyRequests, 0)  // waiting for the words
            expectEqual(session.phase, .thinking)
            transcript(session, "u1", "Hmm.")
            expectEqual(session.replyRequests, 0)
            expectEqual(session.phase, .recording)  // listening again
            expectEqual(store.message(convID, "u1")?.text, "Hmm.")
            expectEqual(reports.last?["outcome"] as? String, "no reply: acknowledgement")  // in the phone's log
            expectEqual(reports.last?["words"] as? String, "Hmm.")
            // With no reply to wait for, its transcript turns final (not grey) right away.
            expect(waitFor(2) { store.message(convID, "u1")?.awaitingCorrection == nil }, "the transcript stayed grey")
            session.stopConversation()
        }
        test("a short real question is answered as soon as its transcript is in") {
            let (session, _, mic, _, _) = makeSession()
            session.startConversation()
            say(session, mic, item: "u1")
            transcript(session, "u1", "What time is it?")
            expectEqual(session.replyRequests, 1)
            expectEqual(session.phase, .thinking)
            session.stopConversation()
        }
        test("\"Okay.\" answering Ilan's question gets a reply") {
            let (session, _, mic, store, convID) = makeSession()
            ilanSaid(store, convID, "Shall I go on? ")
            session.startConversation()
            say(session, mic, item: "u1")
            transcript(session, "u1", "Okay.")
            expectEqual(session.replyRequests, 1)
            session.stopConversation()
        }
        test("a short turn whose transcript is late is answered anyway") {
            let saved = VoiceSession.ackTranscriptWait
            VoiceSession.ackTranscriptWait = 0.1
            defer { VoiceSession.ackTranscriptWait = saved }
            let (session, _, mic, _, _) = makeSession()
            session.startConversation()
            say(session, mic, item: "u1")
            expect(waitFor(1) { session.replyRequests == 1 }, "never answered")
            transcript(session, "u1", "Hmm.")  // too late to matter
            expectEqual(session.replyRequests, 1)
            session.stopConversation()
        }
        test("a longer turn, or one that cuts Ilan off, is answered at once") {
            let (session, speaker, mic, _, _) = makeSession()
            session.startConversation()
            say(session, mic, item: "u1", frames: 120)  // 2.4 s of voice
            expectEqual(session.replyRequests, 1)
            session.handle(["type": "response.created", "response": ["id": "r1"]])
            speaker.isPlaying = true
            session.handle(["type": "response.output_audio.delta", "response_id": "r1", "item_id": "a1",
                            "delta": Data(count: 4800).base64EncodedString()])
            say(session, mic, item: "u2", frames: 50)  // over Ilan: it was cut off, so it answers
            expectEqual(session.replyRequests, 2)
            session.stopConversation()
        }
        test("\"Okay.\" then a real question: one reply, for both") {
            let (session, _, mic, _, _) = makeSession()
            session.startConversation()
            say(session, mic, item: "u1")
            say(session, mic, item: "u2", frames: 120)
            expectEqual(session.replyRequests, 1)
            transcript(session, "u1", "Okay.")
            transcript(session, "u2", "So what happens after that?")
            expectEqual(session.replyRequests, 1)
            session.stopConversation()
        }
        test("waiting for a transcript is not a reply in flight: the next real reply is not cancelled") {
            let (session, speaker, mic, _, _) = makeSession()
            session.startConversation()
            say(session, mic, item: "u1")
            transcript(session, "u1", "")  // no words after all: the turn is removed while it waited
            expectEqual(session.phase, .recording)
            say(session, mic, item: "u2", frames: 120)
            expectEqual(session.replyRequests, 1)
            session.handle(["type": "response.created", "response": ["id": "r2"]])
            speaker.isPlaying = true
            session.handle(["type": "response.output_audio.delta", "response_id": "r2", "item_id": "a2",
                            "delta": Data(count: 4800).base64EncodedString()])
            expectEqual(session.phase, .speaking)
            session.stopConversation()
        }
    }
}
