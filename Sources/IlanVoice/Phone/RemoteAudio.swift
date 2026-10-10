import Foundation

/// Microphone audio that arrives from the iPhone web app, already 24 kHz
/// mono PCM16. Chunks are passed on only while the session is recording.
final class RemoteMicrophone: VoiceInput {
    var onChunk: ((Data, Float) -> Void)?
    private var active = false

    func requestPermission() async -> Bool { true }  // the iPhone asks for the mic itself
    func start() throws { active = true }
    func stop() { active = false }

    func deliver(_ pcm: Data) {
        guard active else { return }
        onChunk?(pcm, Self.level(pcm))
    }

    private static func level(_ pcm: Data) -> Float {
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum = 0.0
            for s in samples { let v = Double(Int16(littleEndian: s)) / 32_768; sum += v * v }
            return Float(min(1, (sum / Double(samples.count)).squareRoot() * 4))
        }
    }
}

/// Plays replies on the iPhone: audio is forwarded as it streams in, and the
/// phone plays it in real time after a short buffer. How much has been heard
/// is estimated from the clock, which is what the session needs to tell the
/// model where Ilan was cut off.
final class RemoteSpeaker: VoiceOutput {
    /// Must match PREBUFFER in the web app.
    static let prebufferSeconds = 0.3

    var onDrained: (() -> Void)?
    var sendAudio: ((Data) -> Void)?
    var sendStop: (() -> Void)?

    private(set) var enqueuedFrames = 0
    private var startedAt: Date?
    private var startFrame = 0
    private var drainWork: DispatchWorkItem?

    var playedFrames: Int {
        guard let startedAt else { return enqueuedFrames }
        let elapsed = Date().timeIntervalSince(startedAt) - Self.prebufferSeconds
        return min(enqueuedFrames, startFrame + max(0, Int(elapsed * PCM.sampleRate)))
    }

    var isPlaying: Bool { startedAt != nil && playedFrames < enqueuedFrames }

    func enqueue(_ pcm: Data) {
        drainWork?.cancel()
        if !isPlaying {
            startedAt = Date()
            startFrame = enqueuedFrames
        }
        enqueuedFrames += pcm.count / 2
        sendAudio?(pcm)
    }

    /// No more audio for now: report "drained" once the phone should be done.
    func flush() {
        drainWork?.cancel()
        let remaining = Double(enqueuedFrames - playedFrames) / PCM.sampleRate
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.startedAt = nil
            self.onDrained?()
        }
        drainWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.1, execute: work)
    }

    func stop() {
        drainWork?.cancel()
        let wasPlaying = isPlaying
        startedAt = nil
        if wasPlaying { sendStop?() }
    }
}
