import AppKit
import SwiftUI
@testable import IlanVoice

/// A narrow window must not squash the replay button or the token counts
/// under a reply (the duration used to wrap one character per line).
@MainActor
func registerReplyFooterTests() {
    /// The height `view` takes when it is given `width`.
    func height<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
    func chip() -> PlayChip {
        let store = ConversationStore()
        let conv = store.newConversation()
        let session = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: FakeSpeaker(),
                                   isRemote: false, target: { conv.id })
        var message = Message(id: "a1", role: .assistant, text: "All set.")
        message.audioFile = "a1.wav"
        message.audioSeconds = 9
        return PlayChip(message: message, session: session, clips: session.clips, dark: false)
    }
    let usage = "in 90.2k (84.0k cached) · out 971"

    suite("Reply footer in a narrow bubble") { test in
        test("the replay button never squeezes: its duration stays on one line") {
            let roomy = height(chip(), width: 400)
            expect(roomy > 0 && roomy < 30, "chip height \(roomy)")
            expectEqual(height(chip(), width: 60), roomy)
        }
        test("side by side when there is room; the tokens move under the button when there isn't") {
            let wide = height(ReplyFooter(usage: usage) { chip() }, width: 600)
            let narrow = height(ReplyFooter(usage: usage) { chip() }, width: 300)
            expect(wide < 30, "one line expected, got \(wide)")
            expect(narrow > wide + 8, "the tokens should go on their own line: \(narrow) vs \(wide)")
            expect(narrow < 60, "two lines expected, got \(narrow)")
        }
        test("no tokens: just the button, one line") {
            expect(height(ReplyFooter(usage: nil) { chip() }, width: 300) < 30)
        }
    }
}
