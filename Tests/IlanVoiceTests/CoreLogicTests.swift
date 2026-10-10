import Carbon.HIToolbox
import Foundation
@testable import IlanVoice

@MainActor
func registerCoreLogicTests() {
    /// 16-bit little-endian mono samples.
    func pcm(_ samples: [Int16]) -> Data { samples.withUnsafeBufferPointer { Data(buffer: $0) } }

    suite("Audio") { test in
        test("seconds follows the Realtime format") {
            expectEqual(PCM.seconds(Data(count: PCM.bytesPerSecond)), 1)
            expectEqual(PCM.seconds(Data(count: PCM.bytesPerSecond / 5)), 0.2)
        }
        test("wav has a 44-byte RIFF header") {
            let wav = PCM.wav(Data(count: 100))
            expectEqual(wav.count, 144)
            expectEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
            expectEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        }
        test("silence and room hiss are not speech") {
            expect(!PCM.containsSpeech(pcm(Array(repeating: 0, count: 24_000))))
            expect(!PCM.containsSpeech(pcm((0..<24_000).map { $0 % 2 == 0 ? 40 : -40 })))
        }
        test("loud audio is speech, a single click is not") {
            let tone = (0..<24_000).map { Int16(8_000 * sin(Double($0) * 0.05)) }
            expect(PCM.containsSpeech(pcm(tone)))
            expect(!PCM.containsSpeech(pcm(Array(tone.prefix(960)) + Array(repeating: 0, count: 23_040))))
        }
        test("tap threshold is 0.2 s") {
            expectEqual(VoiceSession.minRecordingSeconds, 0.2)
        }
    }

    suite("Settings") { test in
        test("speed is clamped and rounded") {
            expectEqual(AppSettings.clampSpeed(0.1), 0.5)
            expectEqual(AppSettings.clampSpeed(9), 1.5)
            expectEqual(AppSettings.clampSpeed(0.8999999999999999), 0.9)
        }
        // The Realtime API rejects 0.90000000000000002, which is how
        // JSONSerialization writes a plain Double 0.9.
        test("speed is written without extra digits") {
            let json = try JSONSerialization.data(withJSONObject: ["speed": AppSettings.speedJSON(0.1 + 0.8)])
            expectEqual(String(decoding: json, as: UTF8.self), #"{"speed":0.9}"#)
        }
    }

    suite("TalkTrigger") { test in
        test("modifiers and mouse buttons") {
            expectEqual(TalkTrigger.modifier(keyCode: kVK_RightOption), .rightOption)
            expect(TalkTrigger.modifier(keyCode: kVK_ANSI_A) == nil)
            expect(TalkTrigger.mouse(button: 0) == nil && TalkTrigger.mouse(button: 1) == nil)
            expectEqual(TalkTrigger.mouse(button: 3)?.name, "Mouse Back button")
            expectEqual(TalkTrigger.mouse(button: 5)?.name, "Mouse button 6")
        }
        test("only modifiers pass through to other apps") {
            expect(!TalkTrigger.rightOption.swallowsInput)
            expect(TalkTrigger.mouse(button: 3)!.swallowsInput)
            expectEqual(TalkTrigger.key(keyCode: kVK_F13, characters: nil).name, "F13")
        }
        test("old drop-down settings migrate") {
            expectEqual(TalkTrigger.migrating(nil), .rightOption)
            expectEqual(TalkTrigger.migrating("mouseBack"), TalkTrigger.mouse(button: 3)!)
            expectEqual(TalkTrigger.migrating("rightCommand").code, kVK_RightCommand)
        }
        test("round-trips through JSON") {
            let trigger = TalkTrigger.mouse(button: 4)!
            expectEqual(try JSONDecoder().decode(TalkTrigger.self, from: JSONEncoder().encode(trigger)), trigger)
        }
    }

    suite("Dictionary") { test in
        test("terms are cleaned and de-duplicated") {
            expectEqual(UserDictionary.terms(from: "Ilan\n# comment\n\n  Kubernetes  \nilan\n<Shi>\n"),
                        ["Ilan", "Kubernetes", "Shi"])
        }
        test("transcription prompt stays under the limit") {
            expect(UserDictionary.transcriptionPrompt([]) == nil)
            let prompt = UserDictionary.transcriptionPrompt((0..<500).map { "term\($0)" }, maxCharacters: 200)!
            expect(prompt.count <= 201 && prompt.hasSuffix("."), prompt)
            expect(UserDictionary.instructions(["A", "B"])?.contains("A; B") == true)
        }
    }

    suite("Titles") { test in
        test("normalize strips decoration") {
            expectEqual(ConversationTitler.normalize("\"Title: Trip to Kyoto.\"\nmore"), "Trip to Kyoto")
            expectEqual(ConversationTitler.normalize("**Weekend plans**"), "Weekend plans")
            expect(ConversationTitler.normalize("  \n") == nil)
        }
        test("clean caps the length on a word boundary") {
            let title = ConversationTitler.clean("Planning a long weekend trip to the mountains with friends")!
            expect(title.count <= ConversationTitler.maxLength && !title.hasSuffix(" "), title)
            expect("Planning a long weekend trip to the mountains".hasPrefix(title), title)
        }
        test("fallback title uses the first eight words") {
            expectEqual(ConversationStore.title(from: "one two three"), "one two three")
            expectEqual(ConversationStore.title(from: "a b c d e f g h i j"), "a b c d e f g h…")
        }
    }

    suite("Transcript") { test in
        test("markdown has every role") {
            var conv = Conversation()
            conv.title = "Test"
            conv.messages = [
                Message(id: "u", role: .user, text: "hi"),
                Message(id: "a", role: .assistant, text: "hello"),
                Message(id: "t", role: .tool, text: "line1\nline2"),
            ]
            let md = ConversationStore.markdown(conv)
            expect(md.hasPrefix("# Test") && md.contains("## You") && md.contains("## Ilan"), md)
            expect(md.contains("> line1\n> line2"), md)
        }
    }

    suite("API keys") { test in
        test("hint never reveals the key") {
            expectEqual(APIKeyCheck.hint(for: "sk-abcdefghijklmnop1234"), "sk-…1234")
            expectEqual(APIKeyCheck.hint(for: "short"), "set")
        }
    }
}
