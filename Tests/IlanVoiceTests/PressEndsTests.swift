import Combine
import Foundation
@testable import IlanVoice

/// The floating pill goes away when a press says how it ended (pressEnded).
/// Every live press must say so exactly once, even when something takes the
/// session over while the key is held; otherwise the pill stays on "Listening"
/// and the mic stays on.
@MainActor
func registerPressEndsTests() {
    func makeSession() -> (VoiceSession, FakeMic) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let speaker = FakeSpeaker(), mic = FakeMic()
        speaker.isPlaying = false  // Ilan is quiet
        mic.framesPerTick = 10     // 0.2 s of speech every 20 ms, so the tests stay quick
        let session = VoiceSession(store: store, mcp: MCPManager(), input: mic, output: speaker,
                                   isRemote: false, target: { conv.id })
        session.conversationID = conv.id
        session.handle(["type": "session.updated"])  // connected
        return (session, mic)
    }
    func outcomes(_ session: VoiceSession) -> (AnyCancellable, () -> [VoiceSession.PressOutcome]) {
        var seen: [VoiceSession.PressOutcome] = []
        let sub = session.pressEnded.sink { seen.append($0) }
        return (sub, { seen })
    }
    /// Holds the talk key until the press is live and has some speech in it.
    func holdAndTalk(_ session: VoiceSession) {
        session.pressToTalk(waitForDoubleTap: true)
        _ = waitFor(2) { session.phase == .recording }
        waitFor(0.05) { false }
    }

    suite("Every press ends") { test in
        test("the connection drops mid-press and resends the message before: the release still ends it") {
            let (session, mic) = makeSession()
            let (sub, seen) = outcomes(session)
            holdAndTalk(session)                 // the first message…
            session.releaseToTalk()
            expect(waitFor(2) { seen() == [.sent] }, "first message not sent: \(seen())")
            holdAndTalk(session)                 // …no reply yet, so the user says something else
            expectEqual(session.phase, .recording)
            session.connectionClosed(reason: "Socket is not connected")  // resends the first message
            expectEqual(session.phase, .thinking)
            session.releaseToTalk()
            expect(waitFor(1) { seen().count == 2 }, "the press never ended: \(seen())")
            expectEqual(seen(), [.sent, .discarded])
            expect(!mic.running, "the mic stayed on")
            expectEqual(session.errorMessage, VoiceSession.lostPressMessage)
            sub.cancel()
        }
        test("a reconnect mid-press (another conversation picked) ends it at the release") {
            let (session, mic) = makeSession()
            let (sub, seen) = outcomes(session)
            holdAndTalk(session)
            session.disconnect()                 // what connect() does first
            session.releaseToTalk()
            expect(waitFor(1) { seen() == [.discarded] }, "the press never ended: \(seen())")
            expect(!mic.running, "the mic stayed on")
            sub.cancel()
        }
        test("taken over in the moment after the release (the last audio arriving): ends once") {
            let (session, _) = makeSession()
            let (sub, seen) = outcomes(session)
            holdAndTalk(session)
            session.releaseToTalk()
            session.disconnect()
            expect(waitFor(1) { !seen().isEmpty }, "the press never ended")
            waitFor(0.05) { false }
            expectEqual(seen(), [.discarded])
            sub.cancel()
        }
    }
}
