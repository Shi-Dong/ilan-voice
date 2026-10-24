import AVFoundation
import Foundation
@testable import IlanVoice

/// A reply's first word isn't lost while headphones wake up.
@MainActor
func registerWarmOutputTests() {
    suite("Speakers wake up before a reply") { test in
        test("a reply finding the speakers off starts with silence for their wake-up; once they are awake, none") {
            var warmth = OutputWarmth()
            let now = Date()
            expectEqual(warmth.leadSilence(at: now), OutputWarmth.wakeSeconds)  // off: all of it
            warmth.switchedOn(at: now)
            expectEqual(warmth.leadSilence(at: now), OutputWarmth.wakeSeconds)  // switched on just as it plays
            expect(abs(warmth.leadSilence(at: now.addingTimeInterval(0.1)) - (OutputWarmth.wakeSeconds - 0.1)) < 0.001)
            expectEqual(warmth.leadSilence(at: now.addingTimeInterval(1.2)), 0)  // woken early, a second before
            warmth.switchedOff()
            expectEqual(warmth.leadSilence(at: now.addingTimeInterval(5)), OutputWarmth.wakeSeconds)
            expect(OutputWarmth.wakeSeconds >= 0.25 && OutputWarmth.wakeSeconds <= 0.5)
            expect(OutputWarmth.idleSeconds >= 30, "headphones would power down between replies")
        }
        test("typing a message wakes the speakers at once, before the reply is even asked for") {
            let store = ConversationStore()
            let conv = store.newConversation()
            let speaker = FakeSpeaker()
            speaker.isPlaying = false
            let session = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: speaker, target: { conv.id })
            _ = session.sendText("What's the weather?")  // no API key here, so nothing is sent
            expectEqual(speaker.warmUps, 1)
            expectEqual(session.sendText("   "), false)  // an empty message wakes nothing
            expectEqual(speaker.warmUps, 1)
        }
        test("while the speakers are on they hum: never digital silence, yet far too quiet to hear") {
            // The same hum StreamPlayer plays, rendered offline (no sound device needed).
            let engine = AVAudioEngine()
            let format = AVAudioFormat(standardFormatWithSampleRate: PCM.sampleRate, channels: 1)!
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_800)
            Hum.attach(to: engine, format: format)
            try engine.start()
            defer { engine.stop() }
            var samples: [Float] = []
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_800)!
            for _ in 0..<5 {  // 1 s
                expectEqual(try engine.renderOffline(4_800, to: buffer), .success)
                samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            }
            let peak = samples.map(abs).max() ?? 0
            expect(peak > 0.0003 && peak <= 0.001, "hum peak \(peak) (about -66 dBFS expected)")
            // No 10 ms without sound: a dongle never sees silence long enough to switch off.
            let window = Int(PCM.sampleRate / 100)
            let silent = stride(from: 0, to: samples.count - window, by: window).filter { start in
                samples[start..<start + window].allSatisfy { $0 == 0 }
            }
            expect(silent.isEmpty, "\(silent.count) silent 10 ms stretches")
        }
        test("a replay waits for the headphones to wake when the speakers were off, and not when they were on") {
            let store = ConversationStore()
            let conv = store.newConversation()
            store.selectedID = conv.id
            let speaker = FakeSpeaker()
            speaker.isPlaying = false
            speaker.wake = 0.02  // the speakers were off: the headphones need a moment
            let session = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: speaker, target: { conv.id })
            session.conversationID = conv.id
            try PCM.wav(Data(count: 4_800)).write(to: store.audioURL(conv.id, "a1.wav"))
            let reply = Message(id: "a1", role: .assistant, text: "Hello there.", audioFile: "a1.wav")
            store.update(conv.id) { $0.messages.append(reply) }
            session.play(reply)
            expect(session.clips.playingID == nil, "played before the headphones were awake")
            expectEqual(session.pendingClip?.id, "a1")
            expect(waitFor(1) { session.clips.playingID == "a1" }, "the replay never started")
            session.clips.stop()
            // The speakers are on now: a replay starts at once.
            speaker.wake = 0
            session.play(reply)
            expectEqual(session.clips.playingID, "a1")
            session.clips.stop()
        }
        test("pressing the talk key while a replay waits for the headphones means it never starts") {
            let store = ConversationStore()
            let conv = store.newConversation()
            store.selectedID = conv.id
            let speaker = FakeSpeaker()
            speaker.isPlaying = false
            speaker.wake = 0.02
            let session = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: speaker, target: { conv.id })
            session.conversationID = conv.id
            try PCM.wav(Data(count: 4_800)).write(to: store.audioURL(conv.id, "a1.wav"))
            let reply = Message(id: "a1", role: .assistant, text: "Hello there.", audioFile: "a1.wav")
            store.update(conv.id) { $0.messages.append(reply) }
            session.play(reply)
            expect(session.interrupt(), "a waiting replay counts as something to stop")
            waitFor(0.06) { false }
            expect(session.clips.playingID == nil, "the replay started after the talk key")
        }
        test("every reply OpenAI starts wakes the speakers, also one after a tool call") {
            let store = ConversationStore()
            let conv = store.newConversation()
            let speaker = FakeSpeaker()
            speaker.isPlaying = false
            let session = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: speaker, target: { conv.id })
            session.conversationID = conv.id
            session.handle(["type": "response.created", "response": ["id": "r1"]])
            session.handle(["type": "response.created", "response": ["id": "r2"]])
            expectEqual(speaker.warmUps, 2)
        }
    }
}
