import Foundation
@testable import IlanVoice

/// Better user transcripts: the transcriber gets Ilan's last reply as
/// context, and a text model corrects misheard words after Ilan answers.
@MainActor
func registerTranscriptQualityTests() {
    suite("Transcription context") { test in
        test("Ilan's last reply follows the vocabulary") {
            let prompt = UserDictionary.transcriptionPrompt(["SGLang", "Miles"], context: "Which devbox should I use?")!
            expect(prompt.hasPrefix("Vocabulary that may appear"), prompt)
            expect(prompt.contains("SGLang, Miles."), prompt)
            expect(prompt.hasSuffix("The user is replying to: \"Which devbox should I use?\""), prompt)
        }
        test("long context keeps its end and the prompt stays under the limit") {
            let long = String(repeating: "word ", count: 400) + "the final question?"
            let prompt = UserDictionary.transcriptionPrompt(["A"], context: long, maxCharacters: 300)!
            expect(prompt.count <= 300, "\(prompt.count)")
            expect(prompt.contains("…") && prompt.hasSuffix("the final question?\""), prompt)
        }
        test("context alone, or no context at all") {
            expectEqual(UserDictionary.transcriptionPrompt([], context: "Hi there"), "The user is replying to: \"Hi there\"")
            expect(UserDictionary.transcriptionPrompt([], context: nil) == nil)
            expect(UserDictionary.transcriptionPrompt([], context: "  \n ") == nil)
        }
        test("context is dropped when the vocabulary leaves no room") {
            let terms = (0..<200).map { "term\($0)" }
            let prompt = UserDictionary.transcriptionPrompt(terms, context: "Hello", maxCharacters: 200)!
            expect(!prompt.contains("replying to"), prompt)
        }
    }

    suite("Transcript correction") { test in
        func msg(_ id: String, _ role: Message.Role, _ text: String, pending: Bool = false) -> Message {
            Message(id: id, role: role, text: text, pending: pending)
        }
        test("waits until the transcript is final and Ilan has answered") {
            expect(TranscriptFixer.turnToCorrect([msg("u", .user, "hi", pending: true)], done: []) == nil)
            expect(TranscriptFixer.turnToCorrect([msg("u", .user, "hi")], done: []) == nil)
            expect(TranscriptFixer.turnToCorrect([msg("u", .user, "hi"), msg("a", .assistant, "...", pending: true)], done: []) == nil)
            let turn = TranscriptFixer.turnToCorrect([msg("u", .user, "hi"), msg("t", .tool, "x"), msg("a", .assistant, "Hello")], done: [])
            expectEqual(turn?.user.id, "u")
            expectEqual(turn?.replies.map(\.id), ["a"])
            expectEqual(turn?.tools.map(\.id), ["t"])
        }
        test("corrects each message once, and only the latest") {
            let messages = [msg("u1", .user, "one"), msg("a1", .assistant, "A"), msg("u2", .user, "two"), msg("a2", .assistant, "B")]
            expectEqual(TranscriptFixer.turnToCorrect(messages, done: [])?.user.id, "u2")
            expect(TranscriptFixer.turnToCorrect(messages, done: ["u2"]) == nil)
            var fixed = messages
            fixed[2].rawText = "too"
            expect(TranscriptFixer.turnToCorrect(fixed, done: []) == nil)
        }
        test("waits for Ilan's whole answer, including tool calls") {
            let turn = [msg("u", .user, "check the box"), msg("a1", .assistant, "Let me check."),
                        msg("t", .tool, "", pending: true)]
            expect(TranscriptFixer.turnToCorrect(turn, done: []) == nil, "a tool call is still running")
            let done = [msg("u", .user, "check the box"), msg("a1", .assistant, "Let me check."),
                        msg("t", .tool, "ok"), msg("a2", .assistant, "It's up.")]
            expect(TranscriptFixer.turnToCorrect(done, done: [], turnFinished: false) == nil, "response still running")
            expectEqual(TranscriptFixer.turnToCorrect(done, done: [])?.replies.map(\.id), ["a1", "a2"])
        }
        test("any non-empty, changed answer is used; length is not checked") {
            expectEqual(TranscriptFixer.accept(original: "launch it on the dev box", corrected: "launch it on the devbox"),
                        "launch it on the devbox")
            expectEqual(TranscriptFixer.accept(original: "ask sigh lang", corrected: "\"ask SGLang\"\n"), "ask SGLang")
            expect(TranscriptFixer.accept(original: "same", corrected: "same") == nil)
            expect(TranscriptFixer.accept(original: "hi", corrected: "  ") == nil)
            let longer = "so um yeah run it on shi-h200-1 and then check the logs on shi-h200-2 as well please"
            expectEqual(TranscriptFixer.accept(original: "so um yeah run it", corrected: longer), longer)
        }
        test("tool calls go in with their arguments, cut when long") {
            var tool = msg("t", .tool, "huge output that is not sent")
            tool.toolName = "run_shell"
            tool.toolArguments = #"{"command":"ssh shi-h200-1 nvidia-smi"}"#
            let input = TranscriptFixer.input("run it on she h two hundred one", dictionary: [], history: [],
                                              tools: [tool], reply: "Running nvidia-smi on shi-h200-1.")
            expect(input.contains("Tool calls the assistant made for this message:\n- run_shell({\"command\":\"ssh shi-h200-1 nvidia-smi\"})"), input)
            expect(!input.contains("huge output"), "tool output must not be sent")
            expect(input.range(of: "Tool calls")!.lowerBound > input.range(of: "Transcript to correct")!.lowerBound)
            tool.toolArguments = String(repeating: "x", count: 2000)
            expectEqual(TranscriptFixer.describe(tool: tool).count, "run_shell(".count + TranscriptFixer.maxToolArguments + 2)
        }
        test("the instructions allow grammar fixes but forbid polishing and rewording") {
            let s = TranscriptFixer.instructions
            expect(s.contains("fix grammar mistakes"), s)
            expect(s.contains("Do not polish, rephrase, shorten, summarise"), s)
            expect(s.contains("do not change the user's word choice, tone or style"), s)
            expect(s.contains("When unsure, leave the word as it is"), s)
            expect(s.contains("tool calls"), s)
        }
        test("the request carries vocabulary, context, transcript and reply") {
            let input = TranscriptFixer.input("run it on shy h two hundred", dictionary: ["shi-h200-1"],
                                              history: [msg("a0", .assistant, "Which box?")], reply: "Starting on shi-h200-1.")
            expect(input.contains("User's vocabulary: shi-h200-1"), input)
            expect(input.contains("Assistant: Which box?"), input)
            expect(input.contains("Transcript to correct:\nrun it on shy h two hundred"), input)
            expect(input.hasSuffix("Assistant's reply to it:\nStarting on shi-h200-1."), input)
        }
    }
}

/// Retrying the transcript correction when OpenAI or the network fails.
@MainActor
func registerTranscriptRetryTests() {
    final class Fake: @unchecked Sendable {
        var replies: [Result<Int, URLError>]
        var calls = 0
        var waits: [TimeInterval] = []
        init(_ replies: [Result<Int, URLError>]) { self.replies = replies }
    }
    let ok = Data(#"{"output_text":"run it on shi-h200-1"}"#.utf8)

    /// Runs `fix` against scripted results: an HTTP status, or a network error.
    func run(_ fake: Fake) async -> String? {
        await TranscriptFixer.fix("run it on she h two hundred one", dictionary: [], history: [], reply: "OK",
                                  apiKey: "test", model: "m",
                                  send: { request in
                                      fake.calls += 1
                                      switch fake.replies.removeFirst() {
                                      case .failure(let e): throw e
                                      case .success(let code):
                                          let r = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                                          return (code == 200 ? ok : Data("{}".utf8), r)
                                      }
                                  },
                                  sleep: { fake.waits.append($0) })
    }
    func blocking(_ body: @escaping () async -> Void) {
        var done = false
        Task { await body(); done = true }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    suite("Transcript correction retries") { test in
        test("server errors and rate limits are retried, then succeed") {
            let fake = Fake([.success(500), .success(429), .success(200)])
            var result: String?
            blocking { result = await run(fake) }
            expectEqual(result, "run it on shi-h200-1")
            expectEqual(fake.calls, 3)
            expectEqual(fake.waits, TranscriptFixer.retryDelays)
        }
        test("a dropped connection is retried") {
            let fake = Fake([.failure(URLError(.networkConnectionLost)), .success(200)])
            var result: String?
            blocking { result = await run(fake) }
            expectEqual(result, "run it on shi-h200-1")
            expectEqual(fake.calls, 2)
        }
        test("a bad key or bad request is not retried") {
            for code in [400, 401, 403, 404] {
                let fake = Fake([.success(code), .success(200)])
                var result: String? = "x"
                blocking { result = await run(fake) }
                expect(result == nil && fake.calls == 1, "\(code): \(fake.calls) calls")
            }
        }
        test("gives up after three attempts and keeps the original") {
            let fake = Fake([.success(503), .success(503), .success(503), .success(200)])
            var result: String? = "x"
            blocking { result = await run(fake) }
            expect(result == nil)
            expectEqual(fake.calls, 3)
        }
    }
}
