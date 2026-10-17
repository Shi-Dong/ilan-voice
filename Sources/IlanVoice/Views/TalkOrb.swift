import SwiftUI

/// The big round button. Hold it (or the talk key) to speak; its rings show
/// your voice level while listening and pulse while Ilan thinks or talks.
struct TalkOrb: View {
    @ObservedObject var session: VoiceSession
    @Local private var pressing = false
    @Local private var hovering = false
    @Local private var spin = false
    @Local private var breathe = false

    private var tint: Color { Theme.color(for: session.phase) }
    private var level: CGFloat { CGFloat(session.inputLevel) }

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(tint.opacity(0.3 - Double(i) * 0.08), lineWidth: 1)
                    .frame(width: 42, height: 42)
                    .scaleEffect(ringScale(i))
                    .animation(.easeOut(duration: 0.12), value: session.inputLevel)
            }
            if session.phase == .thinking || session.phase == .working || session.phase == .connecting {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
            }
            // Clear Liquid Glass like the app's other glass buttons, with a light
            // red icon, drawn at its real size (scaling glass down flattens it
            // into a sticker). The rings and spinner carry the phase colour;
            // while pressed the glass takes a touch of light red.
            Color.clear
                .frame(width: 42, height: 42)
                .glassEffect(.regular.tint(glassTint).interactive(), in: Circle())
                .scaleEffect(hovering && !pressing ? 1.1 : 1)
                .scaleEffect(pressing ? 0.94 : (session.phase == .speaking && breathe ? 1.05 : 1))
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressing)
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 60, height: 60)
        .contentShape(Circle())
        // Hover: the glass grows, lightens and glows faintly light red.
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressing { pressing = true; session.pressToTalk() }
                }
                .onEnded { _ in
                    pressing = false
                    session.releaseToTalk()
                }
        )
        // Breathes only while Ilan talks. A breath that never stopped redrew
        // the window every frame even when idle: the chat re-measured all its
        // messages each time, so the window jittered and the app spun the CPU.
        .onChange(of: session.phase == .speaking, initial: true) { _, speaking in
            if speaking {
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { breathe = true }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { breathe = false }
            }
        }
        .help("Hold to talk")
    }

    private var glassTint: Color {
        if pressing { return Theme.accent.opacity(0.25) }
        return hovering ? Theme.accent.opacity(0.12) : .clear
    }

    private func ringScale(_ i: Int) -> CGFloat {
        switch session.phase {
        case .recording: 1 + level * CGFloat(0.35 + Double(i) * 0.3) + CGFloat(i) * 0.08
        case .speaking: breathe ? 1.12 + CGFloat(i) * 0.14 : 1.02 + CGFloat(i) * 0.08
        default: 1 + CGFloat(i) * 0.08
        }
    }

    private var icon: String {
        switch session.phase {
        case .recording: "waveform"
        case .speaking: "speaker.wave.2.fill"
        case .working: "wrench.and.screwdriver.fill"
        case .thinking: "ellipsis"
        default: "mic.fill"
        }
    }
}
