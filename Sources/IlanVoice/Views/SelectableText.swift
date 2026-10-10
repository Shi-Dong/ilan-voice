import AppKit
import SwiftUI

/// Message text that can be selected. Selecting text shows a small "Add to
/// Message" button on the message's bubble (also at the top of the
/// right-click menu): it
/// quotes the selection into the message box, like "Ask ChatGPT" on the
/// ChatGPT website. SwiftUI's selectable Text gives no
/// access to the selection, hence an NSTextView.
struct SelectableText: NSViewRepresentable {
    let text: String
    var fontSize: CGFloat = 14
    var color: NSColor
    var lineSpacing: CGFloat = 0
    /// The selected text once a selection is finished, or nil when there is none.
    var onSelection: (String?) -> Void = { _ in }

    func makeNSView(context: Context) -> MessageNSTextView {
        let view = MessageNSTextView()
        view.onSelection = onSelection
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        apply(to: view)
        return view
    }

    func updateNSView(_ view: MessageNSTextView, context: Context) {
        view.onSelection = onSelection
        if view.string != text || view.font?.pointSize != fontSize { apply(to: view) }
    }

    private func apply(to view: MessageNSTextView) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]))
        view.font = .systemFont(ofSize: fontSize)
        view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
    }

    /// As wide as the text needs (up to the space offered) and as tall as it wraps.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MessageNSTextView, context: Context) -> CGSize? {
        let maxWidth = proposal.width ?? 600
        guard let container = view.textContainer, let layout = view.layoutManager, maxWidth > 0 else { return nil }
        container.containerSize = NSSize(width: maxWidth, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: min(maxWidth, ceil(used.width)), height: ceil(used.height))
    }
}

final class MessageNSTextView: NSTextView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let range = selectedRange()
        guard range.length > 0 else { return menu }
        let item = NSMenuItem(title: "Add to Message", action: #selector(addSelectionToMessage), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func addSelectionToMessage() {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let selection = (string as NSString).substring(with: range)
        MainActor.assumeIsolated { ComposerModel.shared.addContext(selection) }
    }

    // MARK: Reporting the selection

    /// Tells SwiftUI about finished selections, so the message bubble can show
    /// its own "Add to Message" button. No popover or coordinate maths: the
    /// button is laid out by SwiftUI as part of the bubble.
    var onSelection: ((String?) -> Void)?

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting else { return }
        onSelection?(Self.selectedText(in: string, range: selectedRange()))
    }

    /// Clicking into another message (or the message box) ends this selection,
    /// so only one bubble ever shows the button.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, selectedRange().length > 0 { setSelectedRange(NSRange(location: selectedRange().location, length: 0)) }
        return resigned
    }

    /// The selected text, or nil when nothing (or only whitespace) is selected.
    static func selectedText(in string: String, range: NSRange) -> String? {
        guard range.length > 0, range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length else { return nil }
        let text = (string as NSString).substring(with: range)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// SwiftUI measures this view at several trial widths (sizeThatFits), and
    /// each trial resizes the text container. Re-fit it to the real width
    /// before drawing, so wrapping, selection and positions match the screen.
    override func layout() {
        super.layout()
        let width = bounds.width
        if let container = textContainer, width > 0, abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager?.ensureLayout(for: container)
            needsDisplay = true
        }
    }

    // Containers in a scroll view: let wheel events reach the conversation.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

/// The "Add to Message" button a message bubble shows while some of its text
/// is selected.
struct AddToMessagePill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add to Message", systemImage: "text.quote")
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Theme.inkRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.mint.opacity(0.5)))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.mint)
        .help("Quote the selected text in the message box")
    }
}
