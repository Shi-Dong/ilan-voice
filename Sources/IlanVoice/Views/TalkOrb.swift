import SwiftUI

/// The big round button. Hold it (or the talk key) to speak; its rings show
/// your voice level while listening and pulse while Ilan thinks or talks.
struct TalkOrb: View {
    @ObservedObject var session: VoiceSession
    @Local private var pressing = false
    @Local private var spin = false
    @Local private var breathe = false

    private var tint: Color { Theme.color(for: session.phase) }
    private var level: CGFloat { CGFloat(session.inputLevel) }

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(tint.opacity(0.22 - Double(i) * 0.06), lineWidth: 1.5)
                    .frame(width: 92, height: 92)
                    .scaleEffect(ringScale(i))
                    .animation(.easeOut(duration: 0.12), value: session.inputLevel)
            }
            if session.phase == .thinking || session.phase == .working || session.phase == .connecting {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 104, height: 104)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                    .onDisappear { spin = false }
            }
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                     center: .topLeading, startRadius: 4, endRadius: 110))
                .frame(width: 86, height: 86)
                .shadow(color: tint.opacity(0.45), radius: pressing ? 26 : 14)
                .scaleEffect(pressing ? 0.94 : (session.phase == .speaking && breathe ? 1.05 : 1))
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressing)
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 150, height: 150)
        .contentShape(Circle())
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
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { breathe = true }
        }
        .help("Hold to talk")
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
