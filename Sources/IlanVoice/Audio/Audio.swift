import AVFoundation
import Foundation

/// The Realtime API speaks 24 kHz, mono, 16-bit little-endian PCM both ways.
enum PCM {
    static let sampleRate: Double = 24_000
    static let bytesPerSecond = 48_000

    static func seconds(_ data: Data) -> Double { Double(data.count) / Double(bytesPerSecond) }

    /// Wraps raw PCM in a 44-byte RIFF header.
    static func wav(_ pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(bytesPerSecond)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

/// Microphone → 24 kHz mono PCM16 chunks. The engine only runs while the
/// talk key is held, so the menu-bar mic indicator means "recording".
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: PCM.sampleRate, channels: 1, interleaved: true)!
    /// Called on the audio thread with a PCM chunk and its loudness (0…1).
    var onChunk: ((Data, Float) -> Void)?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "IlanVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "No usable microphone input."])
        }
        let ratio = PCM.sampleRate / inFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            let n = Int(out.frameLength)
            guard n > 0, let samples = out.int16ChannelData?[0] else { return }
            var sum: Float = 0
            for i in 0..<n { let s = Float(samples[i]) / 32768; sum += s * s }
            let level = min(1, sqrt(sum / Float(n)) * 4)
            self.onChunk?(Data(bytes: samples, count: n * 2), level)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Plays PCM16 chunks as they stream in (real-time mode).
///
/// Chunks arrive over the network in uneven bursts. Starting playback on the
/// very first chunk means the speaker soon runs dry and waits for the next
/// burst, which chops up the first sentence. So each reply is held back until
/// `prebufferSeconds` of audio is ready (or the reply ends), then played; once
/// it is playing, later chunks queue behind it.
final class StreamPlayer {
    static let prebufferSeconds = 1.0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: PCM.sampleRate, channels: 1)!
    private var queued = 0
    private var held: [AVAudioPCMBuffer] = []
    private var heldFrames: AVAudioFrameCount = 0
    /// Main-thread callback once every queued chunk has been heard.
    var onDrained: (() -> Void)?

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    var isPlaying: Bool { queued > 0 || !held.isEmpty }

    func enqueue(_ pcm: Data) {
        guard let buffer = makeBuffer(pcm) else { return }
        if node.isPlaying {
            schedule(buffer)
            return
        }
        held.append(buffer)
        heldFrames += buffer.frameLength
        if Double(heldFrames) >= Self.prebufferSeconds * PCM.sampleRate { flush() }
    }

    /// Starts playing whatever is held, even if it is under the threshold
    /// (a short reply, or the end of one).
    func flush() {
        guard !held.isEmpty else { return }
        if !engine.isRunning { try? engine.start() }
        held.forEach(schedule)
        held.removeAll()
        heldFrames = 0
        if !node.isPlaying { node.play() }
    }

    func stop() {
        held.removeAll()
        heldFrames = 0
        queued = 0
        node.stop()
        engine.stop()
    }

    private func makeBuffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let dst = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        return buffer
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        queued += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.queued > 0 else { return }
                self.queued -= 1
                if self.queued == 0 {
                    // Ran dry: stop so the next chunks prebuffer again instead
                    // of trickling out one by one.
                    self.node.stop()
                    if self.held.isEmpty { self.onDrained?() }
                }
            }
        }
    }
}

/// Plays saved WAV files (cached replies and replays of anything).
@MainActor
final class ClipPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?
    @Published private(set) var progress: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var onFinish: (() -> Void)?

    func toggle(id: String, url: URL, onFinish: (() -> Void)? = nil) {
        if playingID == id { stop(); return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.play()
        player = p
        playingID = id
        self.onFinish = onFinish
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        playingID = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            let done = self.onFinish
            self.stop()
            done?()
        }
    }
}
