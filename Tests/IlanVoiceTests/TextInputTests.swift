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

/// What counts as a selection, and where its button goes.
@MainActor
func registerSelectionButtonTests() {
    suite("Add to Message button") { test in
        let text = "Hello world, this is Ilan."
        test("a real selection is reported with its text") {
            expectEqual(MessageNSTextView.selectedText(in: text, range: NSRange(location: 6, length: 5)), "world")
        }
        test("no button for an empty or whitespace-only selection") {
            expect(MessageNSTextView.selectedText(in: text, range: NSRange(location: 3, length: 0)) == nil)
            expect(MessageNSTextView.selectedText(in: text, range: NSRange(location: 5, length: 1)) == nil)
        }
        test("an out-of-range selection is ignored, not a crash") {
            expect(MessageNSTextView.selectedText(in: text, range: NSRange(location: 20, length: 40)) == nil)
            expect(MessageNSTextView.selectedText(in: text, range: NSRange(location: NSNotFound, length: 3)) == nil)
        }

        /// A real message text view, laid out at `width` like SwiftUI does.
        func view(_ string: String, width: CGFloat) -> MessageNSTextView {
            let v = MessageNSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
            v.textContainerInset = .zero
            v.textContainer?.lineFragmentPadding = 0
            v.textContainer?.widthTracksTextView = false
            v.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            v.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            return v
        }
        let para = String(repeating: "word ", count: 60)  // wraps over several lines at 300 pt

        test("the selection rect is on the line the selection starts on") {
            let v = view(para, width: 300)
            let first = v.firstLineRect(of: NSRange(location: 0, length: 4))!
            let later = v.firstLineRect(of: NSRange(location: 200, length: 20))!
            expect(first.minY < 1, "\(first)")
            expect(later.minY > first.maxY, "selection further down must be lower: \(later) vs \(first)")
            expect(later.maxX <= 300.5 && later.minX >= 0, "\(later)")
        }
        test("only the first line counts for a multi-line selection") {
            let v = view(para, width: 300)
            let oneLine = v.firstLineRect(of: NSRange(location: 0, length: 4))!
            let multi = v.firstLineRect(of: NSRange(location: 0, length: 150))!
            expectEqual(multi.minY, oneLine.minY)
            expect(abs(multi.height - oneLine.height) < 0.5, "\(multi) vs \(oneLine)")
        }
        test("the button sits just above the selection and inside the message") {
            let sel = TextSelection(text: "x", firstLine: CGRect(x: 40, y: 60, width: 80, height: 17))
            let o = sel.buttonOrigin(size: CGSize(width: 128, height: 26), width: 300)
            expectEqual(o.x, 40)
            expectEqual(o.y, 60 - 26 - 4)
            let right = TextSelection(text: "x", firstLine: CGRect(x: 280, y: 0, width: 10, height: 17))
            expectEqual(right.buttonOrigin(size: CGSize(width: 128, height: 26), width: 300).x, 172)
        }
    }
}
