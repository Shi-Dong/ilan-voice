@testable import IlanVoice

/// Interrupting Ilan tells OpenAI where the reply was cut, but only when part
/// of it was really unheard.
@MainActor
func registerTruncateTests() {
    suite("Interrupt truncation") { test in
        test("cuts at the heard point while audio is left") {
            expectEqual(VoiceSession.truncationPoint(heardMs: 1_200, itemMs: 5_000), 1_200)
            expectEqual(VoiceSession.truncationPoint(heardMs: 0, itemMs: 5_000), 0)
        }
        test("skips the cut once everything that arrived was heard") {
            expect(VoiceSession.truncationPoint(heardMs: 5_000, itemMs: 5_000) == nil)
            expect(VoiceSession.truncationPoint(heardMs: 7_300, itemMs: 5_000) == nil)
        }
        test("cuts when the reply's length is unknown") {
            expectEqual(VoiceSession.truncationPoint(heardMs: 800, itemMs: nil), 800)
        }
    }
}
