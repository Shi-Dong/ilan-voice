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

        test("the button follows the end the mouse let go at") {
            let r = NSRange(location: 10, length: 20)
            expectEqual(MessageNSTextView.activeEnd(of: r, dragStart: 10), 30)   // dragged forward
            expectEqual(MessageNSTextView.activeEnd(of: r, dragStart: 30), 10)   // dragged backward
            expectEqual(MessageNSTextView.activeEnd(of: r, dragStart: 14), 30)   // double-click inside a word
            expectEqual(MessageNSTextView.activeEnd(of: r, dragStart: nil), 30)  // keyboard
        }
        test("the caret is on the right line of a wrapped paragraph") {
            let v = view(para, width: 300)
            let top = v.caretRect(at: 4)!, lower = v.caretRect(at: 220)!
            expect(top.minY < 1, "\(top)")
            expect(lower.minY > top.maxY, "\(lower) vs \(top)")
            expect(lower.minX >= 0 && lower.minX <= 300.5, "\(lower)")
        }
        test("the caret moves right along a line") {
            let v = view(para, width: 300)
            expect(v.caretRect(at: 10)!.minX > v.caretRect(at: 4)!.minX)
        }
        test("the caret at a line's end stays on that line") {
            let v = view(para, width: 300)
            let lineEnd = (0..<300).first { v.caretRect(at: $0 + 1)!.minY > v.caretRect(at: $0)!.minY }!
            expectEqual(v.caretRect(at: lineEnd)!.minY, v.caretRect(at: 1)!.minY)
        }
        test("the button sits just under the pointer and inside the message") {
            let sel = TextSelection(text: "x", pointer: CGRect(x: 140, y: 60, width: 1, height: 17))
            let o = sel.buttonOrigin(size: CGSize(width: 128, height: 26), width: 300)
            expectEqual(o.x, 128)
            expectEqual(o.y, 81)
            let right = TextSelection(text: "x", pointer: CGRect(x: 295, y: 0, width: 1, height: 17))
            expectEqual(right.buttonOrigin(size: CGSize(width: 128, height: 26), width: 300).x, 172)
        }
    }
}

/// Message text redraws when its colour changes, not only its words.
@MainActor
func registerMessageTextTests() {
    suite("Message text") { test in
        let grey = NSColor(white: 0.5, alpha: 1), dark = NSColor(white: 0.1, alpha: 1)
        func colour(_ v: MessageNSTextView) -> NSColor? {
            v.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        test("a finished transcript loses its grey even when its words are the same") {
            let v = MessageNSTextView()
            v.show(.init(text: "hello there", fontSize: 14, color: grey, lineSpacing: 0))
            expectEqual(colour(v), grey)
            expect(v.show(.init(text: "hello there", fontSize: 14, color: dark, lineSpacing: 0)), "colour change ignored")
            expectEqual(colour(v), dark)
        }
        test("nothing is redone when nothing changed") {
            let v = MessageNSTextView()
            let c = MessageNSTextView.Content(text: "hi", fontSize: 14, color: dark, lineSpacing: 3)
            expect(v.show(c))
            expect(!v.show(c))
        }
        test("a redraw clears the user's selection (and its button)") {
            let v = MessageNSTextView()
            var reported: [TextSelection?] = []
            v.onSelection = { reported.append($0) }
            v.show(.init(text: "hello there", fontSize: 14, color: grey, lineSpacing: 0))
            v.setSelectedRange(NSRange(location: 0, length: 5))
            expectEqual(v.selectedRange().length, 5)
            v.show(.init(text: "hello there", fontSize: 14, color: dark, lineSpacing: 0))
            expectEqual(v.selectedRange().length, 0)
            expect(reported.last.flatMap { $0 } == nil, "the button must be hidden")
        }
        test("new words and line spacing are shown") {
            let v = MessageNSTextView()
            v.show(.init(text: "a", fontSize: 14, color: dark, lineSpacing: 0))
            expect(v.show(.init(text: "b", fontSize: 14, color: dark, lineSpacing: 0)))
            expectEqual(v.string, "b")
            expect(v.show(.init(text: "b", fontSize: 14, color: dark, lineSpacing: 3)))
        }
    }
}

/// Spoken messages stay grey until the Luna correction is done.
@MainActor
func registerProvisionalTests() {
    suite("Grey until corrected") { test in
        test("grey while transcribing and while waiting for the correction") {
            var m = Message(id: "u", role: .user, text: "hi", pending: true)
            expect(m.isProvisional)
            m.pending = false
            m.awaitingCorrection = true
            expect(m.isProvisional)
            m.awaitingCorrection = nil
            expect(!m.isProvisional)
            expect(!Message(id: "t", role: .user, text: "typed", typed: true).isProvisional)
        }
        test("a new message settles earlier ones that will never be corrected") {
            var conv = Conversation()
            var a = Message(id: "a", role: .user, text: "cut off")
            a.awaitingCorrection = true
            conv.messages = [a, Message(id: "r", role: .assistant, text: "ok")]
            VoiceSession.settleEarlierCorrections(&conv)
            expect(conv.messages.allSatisfy { !$0.isProvisional })
        }
        test("after a restart nothing is left waiting") {
            let store = ConversationStore()
            var conv = store.newConversation()
            var m = Message(id: "u", role: .user, text: "hello")
            m.awaitingCorrection = true
            store.update(conv.id) { $0.messages = [m] }
            store.flush()
            let reloaded = ConversationStore()
            conv = reloaded.conversations.first { $0.id == conv.id }!
            expectEqual(conv.messages.first?.awaitingCorrection, nil)
        }
    }
}
