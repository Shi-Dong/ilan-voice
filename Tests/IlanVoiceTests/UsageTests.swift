import Foundation
@testable import IlanVoice

/// Token counts per reply and the cost of each conversation.
@MainActor
func registerUsageTests() {
    /// A Realtime response.done usage object as OpenAI sends it.
    func realtimeUsage(textIn: Int, audioIn: Int, cachedText: Int, cachedAudio: Int, textOut: Int, audioOut: Int) -> [String: Any] {
        ["input_tokens": textIn + audioIn, "output_tokens": textOut + audioOut,
         "input_token_details": ["text_tokens": textIn, "audio_tokens": audioIn, "cached_tokens": cachedText + cachedAudio,
                                 "cached_tokens_details": ["text_tokens": cachedText, "audio_tokens": cachedAudio]],
         "output_token_details": ["text_tokens": textOut, "audio_tokens": audioOut]]
    }
    func makeSession() -> (VoiceSession, UUID) {
        let store = ConversationStore()
        let conv = store.newConversation()
        let session = VoiceSession(store: store, mcp: MCPManager(), input: FakeMic(), output: FakeSpeaker(), target: { conv.id })
        session.conversationID = conv.id
        return (session, conv.id)
    }
    func conversation(_ s: VoiceSession, _ id: UUID) -> Conversation { s.store.conversations.first { $0.id == id }! }

    suite("Usage and cost") { test in
        test("Realtime usage is read with its text, audio and cached parts") {
            let t = TokenUsage.realtime(realtimeUsage(textIn: 1000, audioIn: 500, cachedText: 800, cachedAudio: 100, textOut: 20, audioOut: 300))
            expectEqual(t, TokenUsage(textInput: 1000, audioInput: 500, cachedTextInput: 800, cachedAudioInput: 100, textOutput: 20, audioOutput: 300))
            expectEqual(t.input, 1500); expectEqual(t.cachedInput, 900); expectEqual(t.output, 320)
        }
        test("usage without a breakdown is still counted (as text)") {
            let t = TokenUsage.realtime(["input_tokens": 70, "output_tokens": 9])
            expectEqual(t.input, 70); expectEqual(t.output, 9)
        }
        test("a Realtime reply is priced per kind of token, cached tokens at the cached rate") {
            let t = TokenUsage(textInput: 1_000_000, audioInput: 1_000_000, cachedTextInput: 500_000,
                               cachedAudioInput: 250_000, textOutput: 100_000, audioOutput: 200_000)
            // text: 0.5M × $4 + 0.5M × $0.40 + 0.1M × $24; audio: 0.75M × $32 + 0.25M × $0.40 + 0.2M × $64
            let expected = 2.0 + 0.2 + 2.4 + 24.0 + 0.1 + 12.8
            let cost = Pricing.cost(UsageRecord(model: "gpt-realtime-2.1", tokens: t))!
            expect(abs(cost - expected) < 1e-9, "\(cost)")
        }
        test("an unknown model is never guessed: the total says it is incomplete") {
            let records = [UsageRecord(model: "gpt-realtime-2.1", tokens: TokenUsage(textInput: 1_000_000)),
                           UsageRecord(model: "some-new-model", tokens: TokenUsage(textInput: 5))]
            let total = Pricing.total(records)
            expect(abs(total.dollars - 4) < 1e-9); expect(total.incomplete)
            expectEqual(Pricing.format(total.dollars, incomplete: total.incomplete), "$4.00+")
        }
        test("costs and token counts read naturally") {
            expectEqual(Pricing.format(0), "$0")
            expectEqual(Pricing.format(0.0004), "<$0.001")
            expectEqual(Pricing.format(0.0423), "$0.042")
            expectEqual(Pricing.format(1.237), "$1.24")
            expectEqual(Pricing.describe(TokenUsage(textInput: 12000, audioInput: 345, cachedTextInput: 10240, textOutput: 12, audioOutput: 500)),
                        "in 12,345 (10,240 cached) · out 512")
        }
        test("a reply's tokens are recorded for the cost and shown on its message") {
            let (s, id) = makeSession()
            s.handle(["type": "response.output_item.added", "item": ["id": "a1", "type": "message"]])
            s.handle(["type": "response.done", "response": ["id": "r1", "output": [["id": "a1", "type": "message"]],
                      "usage": realtimeUsage(textIn: 900, audioIn: 0, cachedText: 600, cachedAudio: 0, textOut: 10, audioOut: 200)]])
            let c = conversation(s, id)
            expectEqual(c.usage?.count, 1)
            expectEqual(c.messages.first { $0.id == "a1" }?.usage?.input, 900)
            expect(c.cost.dollars > 0 && !c.cost.incomplete)
        }
        test("tool-calling steps are billed, and their tokens show on the next thing Ilan says") {
            let (s, id) = makeSession()
            s.toolOverride = { _, _ in "ok" }
            s.handle(["type": "response.done", "response": ["id": "r1",
                      "output": [["type": "function_call", "name": "t", "arguments": "{}", "call_id": "c1"]],
                      "usage": realtimeUsage(textIn: 100, audioIn: 0, cachedText: 0, cachedAudio: 0, textOut: 5, audioOut: 0)]])
            s.handle(["type": "response.output_item.added", "item": ["id": "a2", "type": "message"]])
            s.handle(["type": "response.done", "response": ["id": "r2", "output": [["id": "a2", "type": "message"]],
                      "usage": realtimeUsage(textIn: 300, audioIn: 0, cachedText: 0, cachedAudio: 0, textOut: 0, audioOut: 40)]])
            let c = conversation(s, id)
            expectEqual(c.usage?.count, 2)
            expectEqual(c.messages.first { $0.id == "a2" }?.usage, TokenUsage(textInput: 400, textOutput: 5, audioOutput: 40))
        }
        test("a reply the user cut off is still billed") {
            let (s, id) = makeSession()
            let speaker = FakeSpeaker()
            _ = speaker
            s.handle(["type": "response.created", "response": ["id": "r1"]])
            s.interrupt()  // the user stops Ilan: this reply is muted
            s.handle(["type": "response.done", "response": ["id": "r1", "status": "cancelled", "output": [],
                      "usage": realtimeUsage(textIn: 50, audioIn: 0, cachedText: 0, cachedAudio: 0, textOut: 0, audioOut: 30)]])
            expectEqual(conversation(s, id).usage?.count, 1)
        }
        test("conversations saved before this keep loading, with no cost") {
            let old = #"{"id":"6B1D4C2E-0000-4000-8000-000000000001","title":"Old","createdAt":0,"updatedAt":0,"messages":[{"id":"a","role":"assistant","text":"hi","createdAt":0,"pending":false,"listened":true}]}"#
            let c = try JSONDecoder().decode(Conversation.self, from: Data(old.utf8))
            expect(c.usage == nil && c.messages[0].usage == nil)
            expectEqual(c.cost.dollars, 0)
            let round = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(
                Conversation(usage: [UsageRecord(model: "gpt-realtime-2.1", tokens: TokenUsage(textInput: 3))])))
            expectEqual(round.usage?.first?.tokens?.textInput, 3)
        }
        test("only the realtime model counts: transcription, Luna and titles are left out") {
            let (s, id) = makeSession()
            var m = Message(id: "u1", role: .user, text: "", pending: true)
            m.audioSeconds = 30
            s.store.update(id) { $0.messages.append(m) }
            s.handle(["type": "conversation.item.input_audio_transcription.completed", "item_id": "u1", "transcript": "hello",
                      "usage": ["type": "duration", "seconds": 30]])
            expect(conversation(s, id).usage == nil)
            expect(Pricing.tokens["gpt-6-luna"] == nil && Pricing.tokens["gpt-transcribe"] == nil)
        }
        test("the usage display is on by default") {
            expect(AppSettings.shared.showUsage)
        }
    }
}
