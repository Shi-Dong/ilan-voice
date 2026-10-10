import AppKit
import SwiftUI

/// Message text that can be selected. Selecting text shows a small "Add to
/// Message" button above it (also at the top of the right-click menu): it
/// quotes the selection into the message box, like "Ask ChatGPT" on the
/// ChatGPT website. SwiftUI's selectable Text gives no
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
        let range = selectedRange()
        guard range.length > 0 else { return }
        let selection = (string as NSString).substring(with: range)
        Self.closeFloatingButton()
        MainActor.assumeIsolated { ComposerModel.shared.addContext(selection) }
    }

    // MARK: Floating "Add to Message" button

    /// The one button on screen, whichever message it belongs to.
    private static var floatingButton: NSPopover?

    static func closeFloatingButton() {
        floatingButton?.close()
        floatingButton = nil
    }

    /// NSTextView tracks the whole drag inside mouseDown, so the selection
    /// is final when it returns (also after a double- or triple-click).
    override func mouseDown(with event: NSEvent) {
        Self.closeFloatingButton()
        super.mouseDown(with: event)
        showFloatingButtonIfSelected()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if selectedRange().length == 0, Self.floatingButton?.contentViewController?.representedObject as? MessageNSTextView === self {
            Self.closeFloatingButton()
        }
    }

    /// A small pill just above the selection, like ChatGPT's "Ask ChatGPT".
    private func showFloatingButtonIfSelected() {
        let range = selectedRange()
        guard range.length > 0,
              !(string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let layout = layoutManager, let container = textContainer, window != nil else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        // Anchor on the first line of the selection, centred on it.
        let firstLine = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let anchor = NSRect(x: rect.minX, y: rect.minY, width: max(1, min(rect.width, firstLine.width)), height: 1)

        let controller = NSHostingController(rootView: AddToMessagePill { [weak self] in self?.addSelectionToMessage() })
        controller.representedObject = self
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .minY)
        Self.floatingButton = popover
    }

    // Containers in a scroll view: let wheel events reach the conversation.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}

private struct AddToMessagePill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Add to Message", systemImage: "text.quote")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.mint)
        .help("Quote the selected text in the message box")
    }
}
