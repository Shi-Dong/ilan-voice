import AVFoundation
import CoreMedia
import CoreAudio
import Foundation
import os

/// The Realtime API speaks 24 kHz, mono, 16-bit little-endian PCM both ways.
enum PCM {
    static let sampleRate: Double = 24_000
    static let bytesPerSecond = 48_000

    static func seconds(_ data: Data) -> Double { Double(data.count) / Double(bytesPerSecond) }

    /// True if some of the recording is louder than a quiet room: at least
    /// 100 ms, in 20 ms frames, above about -40 dBFS. Background hiss on a
    /// built-in mic sits well below that; normal speech well above.
    static func containsSpeech(_ data: Data) -> Bool { voicedFrames(data) >= 5 }

    /// How many 20 ms frames are above about -40 dBFS (voice, not room hiss).
    static func voicedFrames(_ data: Data) -> Int { voicedFlags(data).filter { $0 }.count }

    /// The most voiced 20 ms frames within any `window` frames in a row:
    /// someone talking packs them densely, while noise over a long stretch
    /// only adds up loud moments here and there.
    static func densestVoice(_ data: Data, windowFrames window: Int) -> Int {
        let flags = voicedFlags(data)
        var best = 0, running = 0
        for i in flags.indices {
            if flags[i] { running += 1 }
            if i >= window, flags[i - window] { running -= 1 }
            best = max(best, running)
        }
        return best
    }

    /// For each whole 20 ms frame: is it above about -40 dBFS?
    private static func voicedFlags(_ data: Data) -> [Bool] {
        let frame = 480, threshold = 0.01 * 32_768.0
        var flags: [Bool] = []
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var start = 0
            while start + frame <= samples.count {
                var sum = 0.0
                for i in start..<start + frame {
                    let v = Double(Int16(littleEndian: samples[i]))
                    sum += v * v
                }
                flags.append((sum / Double(frame)).squareRoot() > threshold)
                start += frame
            }
        }
        return flags
    }

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

/// Microphone → 24 kHz mono PCM16 chunks, from a chosen input device.
///
/// This uses AVCaptureSession rather than AVAudioEngine. On macOS an
/// AVAudioEngine drives input and output through one audio unit, so pointing
/// its input at an input-only device (like a MacBook's built-in microphone)
/// broke recording entirely. A capture session picks an input device on its
/// own and converts to the Realtime API's format for us. It only runs while
/// the talk key is held, so the mic indicator means "recording".
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "ilan-voice.microphone")
    private var input: AVCaptureDeviceInput?
    private var inputUID: String?
    /// The microphone the last `start` records from, as macOS names it.
    private(set) var deviceName: String?
    /// Called on a background queue with a PCM chunk and its loudness (0…1).
    var onChunk: ((Data, Float) -> Void)?

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// - Parameter deviceUID: Core Audio UID of the microphone; nil uses the
    ///   system default input.
    func start(deviceUID: String?) throws {
        guard let device = deviceUID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "IlanVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone found."])
        }
        session.beginConfiguration()
        if inputUID != device.uniqueID {
            if let input { session.removeInput(input) }
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else {
                session.commitConfiguration()
                throw NSError(domain: "IlanVoice", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't record from \(device.localizedName)."])
            }
            session.addInput(newInput)
            input = newInput
            inputUID = device.uniqueID
        }
        if !session.outputs.contains(output) {
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: PCM.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw NSError(domain: "IlanVoice", code: 3, userInfo: [NSLocalizedDescriptionKey: "Can't capture microphone audio."])
            }
            session.addOutput(output)
        }
        session.commitConfiguration()
        deviceName = device.localizedName
        // startRunning blocks for a moment; keep it off the main thread.
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        queue.async { [session] in session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length >= 2 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        let level: Float = data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Float = 0
            for s in samples { let v = Float(Int16(littleEndian: s)) / 32768; sum += v * v }
            return min(1, sqrt(sum / Float(samples.count)) * 4)
        }
        onChunk?(data, level)
    }
}

/// When the speakers were switched on, and so how much silence a reply
/// needs in front of it.
///
/// Headphones on a USB dongle (and Bluetooth ones) power down when nothing
/// plays, and take a moment to sound again once audio starts, often fading
/// in to avoid a pop: whatever plays in that moment is lost, usually the
/// reply's first word. Some (headphone dongles especially) also switch their
/// amplifier off while they get pure digital silence, even with the output
/// open: tried on such a dongle, a replay was cut even with the speakers on,
/// and a second replay right after was whole. So while the speakers are on
/// they play an inaudible hum (`Hum`), never pure silence; they are switched
/// on as soon as a reply is on its way (`StreamPlayer.warmUp`), long before
/// its audio arrives, and stay on for a while after it. If a reply still
/// finds them off, it starts with the rest of the wake-up time (the hum
/// alone), and a replay waits that long.
struct OutputWarmth {
    /// How long headphones may take to sound after switching on.
    static let wakeSeconds = 0.5
    /// How long the speakers stay on with nothing playing (so the headphones can sleep again).
    static let idleSeconds: TimeInterval = 60
    private(set) var onSince: Date?

    mutating func switchedOn(at date: Date = Date()) { onSince = date }
    mutating func switchedOff() { onSince = nil }

    /// Silence to play before a reply starting at `date`: what is left of the wake-up time.
    func leadSilence(at date: Date = Date()) -> TimeInterval {
        guard let onSince else { return Self.wakeSeconds }
        return max(0, Self.wakeSeconds - date.timeIntervalSince(onSince))
    }
}

/// The inaudible hum that keeps headphones awake while the speakers are on:
/// a 40 Hz tone at about -66 dBFS. Far below hearing (the ear is least
/// sensitive that low), but never digital silence, which some headphone
/// dongles take as a cue to switch their amplifier off.
enum Hum {
    static let amplitude: Float = 0.0005
    static let hertz = 40.0

    /// Plays the hum into `engine`'s mixer whenever the engine runs.
    static func attach(to engine: AVAudioEngine, format: AVAudioFormat) {
        let wave = Wave(step: 2 * .pi * hertz / format.sampleRate)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let value = wave.next()
                for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// The tone's phase, kept between render calls (only the audio thread touches it).
    private final class Wave: @unchecked Sendable {
        private var phase = 0.0
        private let step: Double
        init(step: Double) { self.step = step }
        func next() -> Float {
            let value = Float(sin(phase)) * Hum.amplitude
            phase += step
            if phase >= 2 * .pi { phase -= 2 * .pi }
            return value
        }
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
    /// Running totals since the last `stop()`, in samples. Used to work out
    /// how much of a reply was actually heard when it is interrupted.
    private(set) var enqueuedFrames = 0
    private(set) var playedFrames = 0
    private var held: [AVAudioPCMBuffer] = []
    private var heldFrames: AVAudioFrameCount = 0
    /// Main-thread callback once every queued chunk has been heard.
    var onDrained: (() -> Void)?
    private var warmth = OutputWarmth()
    private var idleStop: DispatchWorkItem? { didSet { oldValue?.cancel() } }
    private let log = Logger(subsystem: "me.dongshi.ilan-voice", category: "speakers")

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        Hum.attach(to: engine, format: format)
        engine.prepare()
        // macOS stops the engine when the output changes (headphones plugged
        // in or out, another output chosen): the speakers are off again.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.warmth.switchedOff()
            self.engine.connect(self.node, to: self.engine.mainMixerNode, format: self.format)
            self.log.notice("output changed; the speakers switch on again with the next reply")
        }
    }

    /// Switches the speakers on (with the hum), if they are off, and keeps
    /// them on for now. Returns how long until the headphones are awake.
    @discardableResult func warmUp() -> TimeInterval {
        idleStop = nil
        if !engine.isRunning { warmth.switchedOff() }
        switchOn(early: true)
        stopWhenIdle()
        return warmth.leadSilence()
    }

    private func switchOn(early: Bool) {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            warmth.switchedOn()
            log.notice("speakers switched on \(early ? "early, as a reply is on its way" : "cold, as the reply's audio arrived", privacy: .public)")
        } catch {
            log.error("speakers failed to switch on: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Switches the speakers off after `OutputWarmth.idleSeconds` with nothing playing.
    private func stopWhenIdle() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.engine.stop()
            self.warmth.switchedOff()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + OutputWarmth.idleSeconds, execute: work)
    }

    var isPlaying: Bool { queued > 0 || !held.isEmpty }

    func enqueue(_ pcm: Data) {
        guard let buffer = makeBuffer(pcm) else { return }
        enqueuedFrames += Int(buffer.frameLength)
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
        idleStop = nil
        if !engine.isRunning { warmth.switchedOff() }
        switchOn(early: false)
        // Just switched on: the headphones may still be waking up, so silence goes first.
        let lead = node.isPlaying ? 0 : warmth.leadSilence()
        if lead > 0, let silence = makeBuffer(Data(count: Int(lead * PCM.sampleRate) * 2)) {
            node.scheduleBuffer(silence)  // not counted: nothing of the reply was heard yet
            log.notice("reply starts with \(Int(lead * 1000)) ms of silence while the speakers wake up")
        }
        held.forEach(schedule)
        held.removeAll()
        heldFrames = 0
        if !node.isPlaying { node.play() }
    }

    func stop() {
        held.removeAll()
        heldFrames = 0
        queued = 0
        enqueuedFrames = 0
        playedFrames = 0
        node.stop()
        // The speakers stay on for a while (a reply may follow at once).
        if engine.isRunning { stopWhenIdle() }
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
        let frames = Int(buffer.frameLength)
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.queued > 0 else { return }
                self.queued -= 1
                self.playedFrames += frames
                if self.queued == 0 {
                    // Ran dry: stop so the next chunks prebuffer again instead
                    // of trickling out one by one.
                    self.node.stop()
                    self.stopWhenIdle()
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
    /// The assistant reply heard most recently, live or replayed.
    @Published private(set) var lastPlayed: (id: String, url: URL)?
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
        lastPlayed = (id, url)
        self.onFinish = onFinish
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    /// Records a reply that was heard live, so it can be replayed later.
    func markPlayed(id: String, url: URL) { lastPlayed = (id, url) }

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
