import AppKit
import SwiftUI

/// Message text that can be selected, with "Add to Message" at the top of the
/// right-click menu: it quotes the selection into the message box, like
/// "Ask ChatGPT" on the ChatGPT website. SwiftUI's selectable Text gives no
/// access to the selection, hence an NSTextView.
struct SelectableText: NSViewRepresentable {
    let text: String
    var fontSize: CGFloat = 14
    var color: NSColor
    var lineSpacing: CGFloat = 0

    func makeNSView(context: Context) -> MessageNSTextView {
        let view = MessageNSTextView()
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
        let selection = (string as NSString).substring(with: selectedRange())
        MainActor.assumeIsolated { ComposerModel.shared.addContext(selection) }
    }

    // Containers in a scroll view: let wheel events reach the conversation.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}
