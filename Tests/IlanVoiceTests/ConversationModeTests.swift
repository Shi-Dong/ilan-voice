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
            expectEqual(VoiceSession.semanticTurns["create_response"] as? Bool, true)
            expectEqual(VoiceSession.semanticTurns["interrupt_response"] as? Bool, true)
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
            expect(speaker.stops > stopsBefore, "reply not stopped")
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

/// Conversation turns are transcribed once the conversation ends.
@MainActor
func registerConversationTranscriptTests() {
    func blocking(_ body: @escaping () async -> Void) {
        var done = false
        Task { await body(); done = true }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }
    suite("Conversation transcripts") { test in
        test("speech to text sends the recording, the model and the dictionary prompt") {
            let wav = PCM.wav(Data(count: 4800))
            let r = SpeechToText.request(wav: wav, model: "gpt-transcribe", prompt: "Ilan, MCP", apiKey: "sk-test")
            expectEqual(r.url?.path, "/v1/audio/transcriptions")
            expectEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            let body = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
            expect(body.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
            expect(body.contains("name=\"prompt\"\r\n\r\nIlan, MCP"))
            expect(body.contains("filename=\"turn.wav\""))
            expect(r.httpBody!.count > wav.count)
        }
        test("speech to text reads the text, retries a server error, and gives up on a bad key") {
            blocking {
                var calls = 0
                let ok = await SpeechToText.transcribe(wav: Data(), model: "m", prompt: nil, apiKey: "k",
                    send: { req in
                        calls += 1
                        let status = calls == 1 ? 500 : 200
                        return (Data(#"{"text":" hello there "}"#.utf8),
                                HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
                    }, sleep: { _ in })
                expectEqual(ok, "hello there")
                expectEqual(calls, 2)
                let bad = await SpeechToText.transcribe(wav: Data(), model: "m", prompt: nil, apiKey: "k",
                    send: { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!) },
                    sleep: { _ in })
                expect(bad == nil)
            }
        }
        test("each turn is transcribed, then repaired with what came before and Ilan's reply") {
            blocking {
                let messages = [
                    Message(id: "u1", role: .user, text: ""),
                    Message(id: "a1", role: .assistant, text: "Sure, which cluster?"),
                    Message(id: "u2", role: .user, text: ""),
                    Message(id: "t2", role: .tool, text: "pods: 3"),
                    Message(id: "a2", role: .assistant, text: "Three pods are running."),
                ]
                var seen: [(raw: String, history: [String], tools: [String], reply: String)] = []
                let results = await ConversationTranscriber.finish(
                    ["u1", "u2"], messages: messages,
                    audio: { _ in Data([1]) },
                    transcribe: { _, _ in "raw" },
                    fix: { raw, history, tools, reply in
                        seen.append((raw, history.map(\.text), tools.map(\.text), reply))
                        return "fixed \(seen.count)"
                    })
                expectEqual(results["u1"], .init(raw: "raw", text: "fixed 1"))
                expectEqual(results["u2"], .init(raw: "raw", text: "fixed 2"))
                expectEqual(seen[0].reply, "Sure, which cluster?")
                expectEqual(seen[1].tools, ["pods: 3"])
                expectEqual(seen[1].reply, "Three pods are running.")
                // The second turn sees the first one already repaired.
                expectEqual(seen[1].history, ["fixed 1", "Sure, which cluster?"])
            }
        }
        test("a turn with no words, or no recording, says so instead of staying grey forever") {
            blocking {
                let messages = [Message(id: "u1", role: .user, text: ""), Message(id: "u2", role: .user, text: "")]
                let results = await ConversationTranscriber.finish(
                    ["u1", "u2"], messages: messages,
                    audio: { $0.id == "u1" ? nil : Data([1]) },
                    transcribe: { _, _ in "" },
                    fix: { raw, _, _, _ in raw })
                expectEqual(results["u1"]?.text, "(no words heard)")
                expectEqual(results["u2"]?.text, "(no words heard)")
            }
        }
        test("in a conversation, turns are saved with their own recording and wait for transcription") {
            let store = ConversationStore()
            let conv = store.newConversation()
            let speaker = FakeSpeaker(), mic = FakeMic()
            speaker.isPlaying = false
            let session = VoiceSession(store: store, mcp: MCPManager(), input: mic, output: speaker,
                                       isRemote: true, target: { conv.id })
            session.conversationID = conv.id
            session.startConversation()
            session.handle(["type": "input_audio_buffer.speech_started"])
            waitFor(0.6) { false }  // the fake mic delivers 0.6 s of audio
            session.handle(["type": "input_audio_buffer.speech_stopped"])
            session.handle(["type": "input_audio_buffer.committed", "item_id": "u1"])
            let m = store.message(conv.id, "u1")
            expect(m?.text.isEmpty == true)
            expect(m?.awaitingCorrection == true)
            expect(m?.audioFile != nil)
            // (a loaded CI machine delivers fewer fake chunks, so only require some audio)
            expect((m?.audioSeconds ?? 0) > 0.1, "\(m?.audioSeconds ?? 0) s")
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
            session.conversationSilenceLimit = 0.5
            session.startConversation()
            waitFor(1.1) { false }
            expect(session.conversationActive)
            session.stopConversation()
        }
        test("ending while Ilan is still answering waits for its reply before transcribing") {
            let (session, _, _, store, convID) = makeSession()
            session.startConversation()
            session.handle(["type": "input_audio_buffer.speech_started"])
            session.handle(["type": "input_audio_buffer.speech_stopped"])
            session.handle(["type": "input_audio_buffer.committed", "item_id": "u1"])
            session.handle(["type": "response.created", "response": ["id": "r1"]])
            session.stopConversation()  // Ilan is still answering
            waitFor(0.4) { false }
            expect(store.message(convID, "u1")?.awaitingCorrection == true, "transcribed before Ilan finished")
            session.handle(["type": "response.done", "response": ["id": "r1", "output": []]])
            // No API key in tests: transcription gives nothing, and the turn says so.
            expect(waitFor(2) { store.message(convID, "u1")?.awaitingCorrection == nil }, "never transcribed")
            expectEqual(store.message(convID, "u1")?.text, "(no words heard)")
        }
    }
}
