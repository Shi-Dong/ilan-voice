import AppKit
import Foundation
@testable import IlanVoice

/// Typed messages in the Mac app.
@MainActor
func registerTextInputTests() {
    suite("Text input") { test in
        test("a selection is added as a quote, after what is already typed") {
            expectEqual(ComposerModel.appendingQuote("line one\nline two", to: ""), "> line one\n> line two\n\n")
            expectEqual(ComposerModel.appendingQuote("SGLang", to: "Explain this:  \n"), "Explain this:\n\n> SGLang\n\n")
            expectEqual(ComposerModel.appendingQuote("a\n\nb", to: ""), "> a\n>\n> b\n\n")
        }
        test("an empty selection changes nothing") {
            expectEqual(ComposerModel.appendingQuote("  \n ", to: "keep me"), "keep me")
        }
        test("item ids fit the Realtime API's 32-character limit") {
            let id = VoiceSession.newItemID()
            expect(id.hasPrefix("msg_") && id.count <= 32, id)
            expect(VoiceSession.newItemID() != id)
        }
        test("typed messages are never 'corrected' as transcripts") {
            let messages = [Message(id: "u", role: .user, text: "exact typed text", typed: true),
                            Message(id: "a", role: .assistant, text: "Reply")]
            expect(TranscriptFixer.turnToCorrect(messages, done: []) == nil)
        }
        test("without an API key nothing is sent and the draft stays") {
            let store = ConversationStore()
            let conv = store.newConversation()
            let session = VoiceSession(store: store, mcp: MCPManager(), target: { conv.id })
            expect(!session.sendText("hello"))
            expect(store.conversations.first { $0.id == conv.id }?.messages.isEmpty == true)
            expect(!session.sendText("   "))
        }
        test("a typed message is saved and round-trips as typed") {
            let message = Message(id: "u", role: .user, text: "hi", typed: true)
            let decoded = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
            expectEqual(decoded.typed, true)
        }
    }
}

/// Where the "Add to Message" pill is anchored.
@MainActor
func registerSelectionButtonTests() {
    suite("Add to Message button") { test in
        test("centred on the pointer, one line tall") {
            let (r, _) = MessageNSTextView.anchor(at: NSPoint(x: 120, y: 50), lineHeight: 18, flipped: true)
            expectEqual(r.midX, 120)
            expectEqual(r.midY, 50)
            expectEqual(r.height, 18)
        }
        test("the pill goes above the line in flipped and unflipped views") {
            expectEqual(MessageNSTextView.anchor(at: .zero, lineHeight: 18, flipped: true).1, NSRectEdge.minY)
            expectEqual(MessageNSTextView.anchor(at: .zero, lineHeight: 18, flipped: false).1, NSRectEdge.maxY)
        }
    }
}
