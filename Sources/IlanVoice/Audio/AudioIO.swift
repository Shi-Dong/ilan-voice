import Foundation

/// Where a voice session's microphone audio comes from: this Mac's
/// microphone, or the iPhone web app (see PhoneServer).
protocol VoiceInput: AnyObject {
    /// 24 kHz mono PCM16 chunks and their level (0…1).
    var onChunk: ((Data, Float) -> Void)? { get set }
    func requestPermission() async -> Bool
    func start() throws
    func stop()
}

/// Where a voice session's replies are played: this Mac's speakers, or the
/// iPhone web app.
protocol VoiceOutput: AnyObject {
    var onDrained: (() -> Void)? { get set }
    var isPlaying: Bool { get }
    var enqueuedFrames: Int { get }
    var playedFrames: Int { get }
    func enqueue(_ pcm: Data)
    func flush()
    func stop()
}

/// This Mac's microphone, following the microphone chosen in Settings.
final class MacMicrophone: VoiceInput {
    private let capture = MicrophoneCapture()

    var onChunk: ((Data, Float) -> Void)? {
        get { capture.onChunk }
        set { capture.onChunk = newValue }
    }

    func requestPermission() async -> Bool { await MicrophoneCapture.requestPermission() }

    func start() throws {
        try capture.start(deviceUID: AudioDevices.resolveUID(AppSettings.shared.microphone))
    }

    func stop() { capture.stop() }
}

extension StreamPlayer: VoiceOutput {}
