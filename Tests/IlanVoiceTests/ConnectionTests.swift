@testable import IlanVoice

/// A dropped Realtime connection only warns the user when it cost them a reply.
@MainActor
func registerConnectionTests() {
    suite("Connection warnings") { test in
        test("idle drops are silent; the next press reconnects") {
            for phase: VoiceSession.Phase in [.offline, .connecting, .ready, .recording] {
                expect(!VoiceSession.shouldReport(closeReason: "Socket is not connected", phase: phase, responseActive: false),
                       phase.label)
            }
        }
        test("drops while a reply is on its way are reported") {
            for phase: VoiceSession.Phase in [.thinking, .working, .speaking] {
                expect(VoiceSession.shouldReport(closeReason: "The socket is closed", phase: phase, responseActive: false),
                       phase.label)
            }
            expect(VoiceSession.shouldReport(closeReason: "Socket is not connected", phase: .ready, responseActive: true))
        }
        test("a clean close or no reason is never reported") {
            expect(!VoiceSession.shouldReport(closeReason: "Connection closed", phase: .thinking, responseActive: true))
            expect(!VoiceSession.shouldReport(closeReason: nil, phase: .thinking, responseActive: true))
            expect(!VoiceSession.shouldReport(closeReason: "", phase: .speaking, responseActive: true))
        }
        test("the 60-minute session limit is recognised") {
            expect(VoiceSession.isSessionExpiry(code: "session_expired", message: ""))
            expect(VoiceSession.isSessionExpiry(code: nil, message: "Your session hit the maximum duration of 60 minutes."))
            expect(!VoiceSession.isSessionExpiry(code: "invalid_value", message: "Invalid value for speed"))
        }
        test("old sessions are replaced before OpenAI's 60-minute limit") {
            expect(VoiceSession.sessionRefreshAge < 60 * 60)
            expect(VoiceSession.sessionRefreshAge >= 30 * 60)  // not needlessly often
        }
    }
}
