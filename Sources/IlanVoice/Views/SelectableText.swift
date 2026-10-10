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
        // The event that ended the drag: the button goes where the mouse let go.
        let release = NSApp.currentEvent.flatMap { $0.window === window ? $0.locationInWindow : nil }
            ?? event.locationInWindow
        showFloatingButtonIfSelected(at: convert(release, from: nil))
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

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if selectedRange().length == 0, Self.floatingButton?.contentViewController?.representedObject as? MessageNSTextView === self {
            Self.closeFloatingButton()
        }
    }

    /// A small pill just above where the selection ended, like ChatGPT's
    /// "Ask ChatGPT". Anchored to the mouse rather than to computed text
    /// geometry, which is what put it far from the selection before.
    private func showFloatingButtonIfSelected(at point: NSPoint) {
        let range = selectedRange()
        guard range.length > 0,
              !(string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              window != nil else { return }
        let anchor = Self.anchorRect(at: point, in: bounds, lineHeight: layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 14)) ?? 17)

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

    /// A one-line-tall rect at the release point, kept inside the view, so the
    /// popover sits right above the line the user finished selecting on.
    static func anchorRect(at point: NSPoint, in bounds: NSRect, lineHeight: CGFloat) -> NSRect {
        let x = min(max(point.x, bounds.minX), bounds.maxX)
        // Flipped view: the line under the pointer starts about half a line above it.
        let top = min(max(point.y - lineHeight / 2, bounds.minY), max(bounds.minY, bounds.maxY - lineHeight))
        return NSRect(x: x - 1, y: top, width: 2, height: lineHeight)
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
