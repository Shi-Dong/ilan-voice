import Foundation
@testable import IlanVoice

/// The conversation is renamed from the user's corrected words: only after
/// Luna has fixed the latest spoken message, never from the raw transcript.
@MainActor
func registerTitleAfterCorrectionTests() {
    final class Seen { var titleInputs: [String] = []; var fixes = 0 }
    func makeSession() -> (VoiceSession, UUID, Seen) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let speaker = FakeSpeaker(), mic = FakeMic()
        speaker.isPlaying = false
        let session = VoiceSession(store: store, mcp: MCPManager(), input: mic, output: speaker,
                                   isRemote: false, target: { conv.id })
        session.conversationID = conv.id
        let seen = Seen()
        session.titleOverride = { messages in
            seen.titleInputs.append(messages.first { $0.role == .user }?.text ?? "")
            return "Qwerty keyboards"
        }
        session.transcriptFixOverride = { text in
            seen.fixes += 1
            try? await Task.sleep(nanoseconds: 10_000_000)  // Luna takes a moment
            return text.replacingOccurrences(of: "kwerty", with: "qwerty")
        }
        return (session, conv.id, seen)
    }
    /// The user's spoken turn arrives at OpenAI.
    func userSpoke(_ session: VoiceSession) {
        session.handle(["type": "input_audio_buffer.committed", "item_id": "u1"])
    }
    /// Ilan answers with one message, all the way to response.done.
    func ilanAnswers(_ session: VoiceSession) {
        session.handle(["type": "response.created", "response": ["id": "r1"]])
        session.handle(["type": "response.output_item.added", "item": ["id": "a1", "type": "message"]])
        session.handle(["type": "response.output_audio_transcript.delta", "item_id": "a1", "delta": "Sure."])
        session.handle(["type": "response.output_item.done", "item": ["id": "a1", "type": "message"]])
        session.handle(["type": "response.done", "response": ["id": "r1", "output": [[String: Any]]()]])
    }

    suite("Renaming after the transcript is corrected") { test in
        test("a spoken message is renamed from Luna's corrected words, once") {
            let (session, convID, seen) = makeSession()
            userSpoke(session)
            session.handle(["type": "conversation.item.input_audio_transcription.completed", "item_id": "u1",
                            "transcript": "tell me about kwerty keyboards"])
            ilanAnswers(session)
            expectEqual(seen.titleInputs, [])  // not yet: Luna is still correcting
            expectEqual(session.store.conversations.first { $0.id == convID }?.title, "New conversation")  // not the misheard words
            expect(waitFor(2) { !seen.titleInputs.isEmpty }, "never renamed")
            expectEqual(seen.fixes, 1)
            expectEqual(seen.titleInputs, ["tell me about qwerty keyboards"])
            expectEqual(session.store.conversations.first { $0.id == convID }?.title, "Qwerty keyboards")
        }
        test("the transcript arriving after Ilan's answer: still renamed only once corrected") {
            let (session, _, seen) = makeSession()
            userSpoke(session)
            ilanAnswers(session)
            expectEqual(seen.titleInputs, [])  // the user's words aren't even in yet
            session.handle(["type": "conversation.item.input_audio_transcription.completed", "item_id": "u1",
                            "transcript": "tell me about kwerty keyboards"])
            expect(waitFor(2) { !seen.titleInputs.isEmpty }, "never renamed")
            expectEqual(seen.titleInputs, ["tell me about qwerty keyboards"])
        }
        test("before the rename, the stand-in title is the corrected first words") {
            let (session, convID, seen) = makeSession()
            session.titleOverride = { _ in nil }  // the title model fails: the stand-in stays
            userSpoke(session)
            session.handle(["type": "conversation.item.input_audio_transcription.completed", "item_id": "u1",
                            "transcript": "tell me about kwerty keyboards"])
            ilanAnswers(session)
            expect(waitFor(2) { seen.fixes == 1 && session.store.conversations.first { $0.id == convID }?.title != "New conversation" })
            expectEqual(session.store.conversations.first { $0.id == convID }?.title, "tell me about qwerty keyboards")
        }
        test("a failed transcription (nothing to correct) is still renamed") {
            let (session, _, seen) = makeSession()
            userSpoke(session)
            ilanAnswers(session)
            session.handle(["type": "conversation.item.input_audio_transcription.failed", "item_id": "u1"])
            expect(waitFor(1) { seen.titleInputs.count == 1 }, "never renamed")
            expectEqual(seen.fixes, 0)
        }
    }
}
