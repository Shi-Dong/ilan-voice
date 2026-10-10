import AppKit
import Combine
import SwiftUI

/// The text in the message box. Kept across window closes, conversation
/// switches and restarts until it is sent or cleared.
@MainActor
final class ComposerModel: ObservableObject {
    static let shared = ComposerModel()
    private static let draftKey = "composerDraft"

    @Published var draft: String {
        didSet { UserDefaults.standard.set(draft, forKey: Self.draftKey) }
    }
    /// Asks the message box to take keyboard focus (and put the cursor at the end).
    let focusRequests = PassthroughSubject<Void, Never>()

    private init() {
        draft = UserDefaults.standard.string(forKey: Self.draftKey) ?? ""
    }

    /// "Add to Message" on a text selection in the conversation.
    func addContext(_ selection: String) {
        draft = Self.appendingQuote(selection, to: draft)
        focusRequests.send()
    }

    /// The draft with `selection` added as a quote: each line prefixed with
    /// "> ", separated from what is already there by a blank line, and
    /// followed by an empty line ready for the question about it.
    static func appendingQuote(_ selection: String, to draft: String) -> String {
        let lines = selection.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return draft }
        let quote = lines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        let head = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (head.isEmpty ? "" : head + "\n\n") + quote + "\n\n"
    }
}

/// The message box under the conversation: Enter sends, Shift+Enter adds a
/// line, ⓧ clears it. Focused whenever the window comes to the front.
struct ComposerBar: View {
    @ObservedObject var model = ComposerModel.shared
    @ObservedObject var session: VoiceSession
    let talkKey: String
    @Local private var height: CGFloat = 20

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if model.draft.isEmpty {
                    Text("Message Ilan, or hold \(talkKey) to talk")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textDim)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $model.draft, height: $height, onSubmit: send)
                    .frame(height: height)
            }
            .padding(.vertical, 2)
            if !model.draft.isEmpty {
                Button { model.draft = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
                .help("Clear the message")
                .padding(.bottom, 3)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mint)
                .disabled(session.phase == .recording)
                .help("Send (Enter). Shift+Enter adds a line.")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline))
    }

    private func send() {
        guard session.sendText(model.draft) else { return }
        model.draft = ""
    }
}

/// An NSTextView, because SwiftUI's text fields can't tell Enter from
/// Shift+Enter or be focused when the window comes to the front.
private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let onSubmit: () -> Void
    static let maxLines: CGFloat = 8

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = ComposerNSTextView()
        view.delegate = context.coordinator
        view.onSubmit = onSubmit
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 13.5)
        view.textColor = .white
        view.insertionPointColor = NSColor(Theme.mint)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.string = text
        scroll.documentView = view
        context.coordinator.textView = view
        context.coordinator.observe()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerNSTextView else { return }
        view.onSubmit = onSubmit
        if view.string != text {
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        DispatchQueue.main.async { context.coordinator.updateHeight() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        private var cancellables: Set<AnyCancellable> = []

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            parent.text = view.string
            updateHeight()
        }

        func updateHeight() {
            guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: view.font ?? .systemFont(ofSize: 13.5))
            let used = max(line, ceil(layout.usedRect(for: container).height))
            let target = min(used, line * ComposerTextView.maxLines)
            if abs(parent.height - target) > 0.5 { parent.height = target }
        }

        /// Focus when the window becomes key (opening it, switching to it) or
        /// when asked, unless another text field already has the keyboard.
        func observe() {
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
                .sink { [weak self] note in
                    guard let self, let view = self.textView, note.object as? NSWindow === view.window else { return }
                    self.focus(onlyIfFree: true)
                }
                .store(in: &cancellables)
            ComposerModel.shared.focusRequests
                .sink { [weak self] in self?.focus(onlyIfFree: false) }
                .store(in: &cancellables)
            DispatchQueue.main.async { [weak self] in self?.focus(onlyIfFree: true) }
        }

        func focus(onlyIfFree: Bool) {
            guard let view = textView, let window = view.window else { return }
            if onlyIfFree, let current = window.firstResponder as? NSTextView, current !== view, current.isEditable { return }
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.scrollRangeToVisible(view.selectedRange())
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // Shift+Enter adds a line; so does Enter while an input method is composing.
        if isReturn, !event.modifierFlags.contains(.shift), !hasMarkedText() {
            onSubmit?()
            return
        }
        if isReturn, event.modifierFlags.contains(.shift) {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }
}
