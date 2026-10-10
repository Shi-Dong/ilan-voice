import SwiftUI

struct MessageRow: View {
    let message: Message
    @ObservedObject var session: VoiceSession
    @ObservedObject var clips: ClipPlayer
    /// Text selected in this message, if any: shows "Add to Message" on the bubble.
    @Local private var selection: TextSelection?

    var body: some View {
        Group {
            switch message.role {
            case .user: userBubble
            case .assistant: assistantCard
            case .tool: ToolRow(message: message)
            }
        }
        // The button may stick out above the bubble: draw over the row above.
        .zIndex(selection == nil ? 0 : 1)
    }

    /// Sits right under where the mouse let go, inside this message's own layout.
    private func selectionButton(width: CGFloat) -> some View {
        Group {
            if let selection {
                let origin = selection.buttonOrigin(size: AddToMessagePill.size, width: width)
                AddToMessagePill {
                    ComposerModel.shared.addContext(selection.text)
                    self.selection = nil
                }
                .frame(width: AddToMessagePill.size.width, height: AddToMessagePill.size.height)
                .offset(x: origin.x, y: origin.y)
                .transition(.opacity)
            }
        }
    }

    /// Message text with the selection button overlaid at the selection.
    private func messageText(_ text: String, color: NSColor, lineSpacing: CGFloat = 0) -> some View {
        SelectableText(text: text, color: color, lineSpacing: lineSpacing, onSelection: { selection = $0 })
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in selectionButton(width: geo.size.width) }
            }
    }

    private var userBubble: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                messageText(message.text.isEmpty ? "Transcribing…" : message.text,
                            color: NSColor(message.pending ? Theme.ink.opacity(0.55) : Theme.ink))
                if message.audioFile != nil {
                    PlayChip(message: message, session: session, clips: clips, dark: true)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.mint, in: BubbleShape(mine: true))

        }
    }

    private var assistantCard: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(size: 26)
            VStack(alignment: .leading, spacing: 8) {
                if message.text.isEmpty && message.pending {
                    TypingDots()
                } else {
                    messageText(message.text, color: NSColor(white: 1, alpha: 0.92), lineSpacing: 3)
                }
                if message.audioFile != nil {
                    PlayChip(message: message, session: session, clips: clips, dark: false)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Theme.card, in: BubbleShape(mine: false))
            .overlay(BubbleShape(mine: false).stroke(message.listened ? Theme.hairline : Theme.orange.opacity(0.6)))

            Spacer(minLength: 80)
        }
    }
}

/// Play/pause pill with a progress bar, a duration, and a "new" dot for
/// cached replies that have not been heard yet.
struct PlayChip: View {
    let message: Message
    @ObservedObject var session: VoiceSession
    @ObservedObject var clips: ClipPlayer
    let dark: Bool

    var body: some View {
        let playing = clips.playingID == message.id
        let fg = dark ? Theme.ink : Color.white
        Button { session.play(message) } label: {
            HStack(spacing: 8) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(dark ? Theme.ink.opacity(0.12) : (message.listened ? Color.white.opacity(0.12) : Theme.orange), in: Circle())
                    .foregroundStyle(dark || message.listened ? fg : Theme.ink)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(fg.opacity(0.15))
                        Capsule().fill(fg.opacity(0.7))
                            .frame(width: geo.size.width * (playing ? clips.progress : 0))
                    }
                }
                .frame(width: 90, height: 3)
                Text(formatDuration(message.audioSeconds))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(fg.opacity(0.6))
                if !message.listened {
                    Text("NEW")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.orange)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct ToolRow: View {
    let message: Message
    @Local private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    if message.pending {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 10))
                    }
                    Text(message.toolName?.replacingOccurrences(of: "__", with: " › ") ?? "tool")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.card, in: Capsule())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.toolArguments ?? "{}")
                        .foregroundStyle(Theme.mint.opacity(0.8))
                    Divider().overlay(Theme.hairline)
                    Text(message.text.prefix(4000))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: 560, alignment: .leading)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.leading, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TypingDots: View {
    @Local private var on = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(.white.opacity(0.6)).frame(width: 6, height: 6)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: on)
            }
        }
        .padding(.vertical, 4)
        .onAppear { on = true }
    }
}

struct BubbleShape: Shape {
    let mine: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 16, tail: CGFloat = 5
        return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: mine ? r : tail, bottomLeading: r,
            bottomTrailing: mine ? tail : r, topTrailing: r), style: .continuous)
    }
}
