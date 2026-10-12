import Foundation
@testable import IlanVoice

/// The floating pill names the microphone that is recording.
@MainActor
func registerPillMicrophoneTests() {
    suite("Pill shows the microphone") { test in
        test("a recording knows which microphone it uses, press by press") {
            let store = ConversationStore()
            let conv = store.newConversation()
            let speaker = FakeSpeaker(), mic = FakeMic()
            speaker.isPlaying = false  // Ilan is quiet: presses record straight away
            mic.deviceName = "Boom Headset"
            let session = VoiceSession(store: store, mcp: MCPManager(), input: mic, output: speaker, target: { conv.id })
            session.pressToTalk()
            expect(waitFor(1) { session.phase == .recording }, "never recorded")
            expectEqual(session.microphoneName, "Boom Headset")
            session.cancelRecording()
            // Unplugged: the next press records from another microphone, and says so.
            mic.deviceName = "MacBook Pro Microphone"
            session.pressToTalk()
            expect(waitFor(1) { session.phase == .recording }, "never recorded")
            expectEqual(session.microphoneName, "MacBook Pro Microphone")
            session.cancelRecording()
        }
        test("the listening pill shows the microphone's name") {
            let model = HUDModel()
            model.mode = .sent
            model.push(0.5)
            model.listen(microphone: "AirPods Pro")
            expect(model.mode == .listening)
            expectEqual(model.microphone, "AirPods Pro")
            expect(model.levels.allSatisfy { $0 == 0 })  // fresh bars
            model.listen(microphone: nil)
            expect(model.microphone == nil)  // unknown: no name, no stale one
        }
        test("blank names show nothing; long names are cut short") {
            expect(HUDModel.microphoneLabel(nil) == nil)
            expect(HUDModel.microphoneLabel("  \n") == nil)
            expectEqual(HUDModel.microphoneLabel(" Studio Display Microphone "), "Studio Display Microphone")
            let long = HUDModel.microphoneLabel("Jabra Evolve2 65 Flex Bluetooth Headset with Boom")!
            expectEqual(long, "Jabra Evolve2 65 Flex Bluetoo…")
            expect(long.count <= HUDModel.microphoneMaxLength)
            let exact = String(repeating: "x", count: HUDModel.microphoneMaxLength)
            expectEqual(HUDModel.microphoneLabel(exact), exact)
        }
    }
}
