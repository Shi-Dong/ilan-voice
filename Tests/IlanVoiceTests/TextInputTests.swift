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
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 100)
        test("anchored at the release point, one line tall") {
            let r = MessageNSTextView.anchorRect(at: NSPoint(x: 120, y: 50), in: bounds, lineHeight: 18)
            expectEqual(r.midX, 120)
            expectEqual(r.minY, 41)
            expectEqual(r.height, 18)
        }
        test("kept inside the message when the mouse ends outside it") {
            let r = MessageNSTextView.anchorRect(at: NSPoint(x: 900, y: -40), in: bounds, lineHeight: 18)
            expect(r.midX <= bounds.maxX && r.minY >= bounds.minY, "\(r)")
            let below = MessageNSTextView.anchorRect(at: NSPoint(x: -20, y: 400), in: bounds, lineHeight: 18)
            expect(below.midX >= bounds.minX && below.maxY <= bounds.maxY, "\(below)")
        }
    }
}
