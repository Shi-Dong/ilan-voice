import Foundation
@testable import IlanVoice

/// An iPhone page as the Mac sees it, over a real local WebSocket: everything
/// the Mac sends it is collected in order (JSON messages and audio bytes).
@MainActor
final class FakePage {
    enum Frame { case json([String: Any]), audio(Int) }
    let task: URLSessionWebSocketTask
    private(set) var frames: [Frame] = []
    init(port: UInt16) {
        task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        task.resume()
        read()
    }
    private func read() {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, case .success(let message) = result else { return }
                switch message {
                case .string(let text): self.frames.append(.json(json(.string(text))))
                case .data(let data): self.frames.append(.audio(data.count))
                @unknown default: break
                }
                self.read()
            }
        }
    }
    func say(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        send(task, .string(String(decoding: data, as: UTF8.self)))
    }
    func sendAudio(_ data: Data) { send(task, .data(data)) }
    var messages: [[String: Any]] { frames.compactMap { if case .json(let m) = $0 { return m } else { return nil } } }
    func first(_ type: String) -> [String: Any]? { messages.first { $0["type"] as? String == type } }
    /// Reply audio as the page saw it: (item, where it started, bytes) per "reply" marker.
    var replies: [(item: String, at: Int, bytes: Int)] {
        var out: [(String, Int, Int)] = []
        for frame in frames {
            switch frame {
            case .json(let m) where m["type"] as? String == "reply":
                out.append((m["item"] as? String ?? "", m["at"] as? Int ?? -1, 0))
            case .audio(let n): if !out.isEmpty { out[out.count - 1].2 += n }
            default: break
            }
        }
        return out.map { (item: $0.0, at: $0.1, bytes: $0.2) }
    }
    var audioBytes: Int { frames.reduce(0) { if case .audio(let n) = $1 { return $0 + n } else { return $0 } } }
}

/// The Mac's side of a bad network: a page that drops and comes back is sent
/// exactly what it missed of Ilan's reply, and sends what the Mac missed of
/// the microphone; speech while away comes first.
@MainActor
func registerReconnectTests() {
    /// A phone with a conversation on, its first page connected.
    func setUp(_ device: String) throws -> (PhoneServer, UInt16, PhoneClient, FakePage) {
        let store = ConversationStore()
        let phone = PhoneServer(store: store, mcp: MCPManager())
        let port = try startOnSparePort(phone.http)
        let page = FakePage(port: port)
        page.say(["type": "hello", "token": phone.token, "device": device, "conversing": false])
        _ = waitFor(2) { page.first("hello_ok") != nil }
        guard let client = phone.client(for: device) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no client; the page got \(page.frames.count) frames: \(page.messages)"])
        }
        page.say(["type": "conversation_start"])
        _ = waitFor(2) { client.session.conversationActive }
        client.session.conversationID = store.iPhoneConversation(device: device, create: false)  // no OpenAI here
        return (phone, port, client, page)
    }
    /// The page back after a drop, from this version: it says how much it
    /// recorded and where it was in the reply. Returns it once hello_ok is in.
    func comeBack(_ phone: PhoneServer, _ port: UInt16, _ device: String, micSent: Int,
                  item: String?, bytes: Int, queuedMs: Int = 0) -> FakePage {
        let page = FakePage(port: port)
        page.say(["type": "hello", "token": phone.token, "device": device, "conversing": true, "micSent": micSent,
                  "playback": ["item": item.map { $0 as Any } ?? NSNull(), "bytes": bytes, "queuedMs": queuedMs]])
        _ = waitFor(2) { page.first("hello_ok") != nil }
        return page
    }
    func catchUp(_ page: FakePage, _ audio: Data = Data()) {
        page.say(["type": "catchup", "bytes": audio.count, "lost": 0])
        if !audio.isEmpty { page.sendAudio(audio) }
        page.say(["type": "catchup_end"])
    }
    func reply(_ session: VoiceSession, _ item: String, bytes: Int, response: String = "r1") {
        session.handle(["type": "response.output_audio.delta", "response_id": response, "item_id": item,
                        "delta": Data(count: bytes).base64EncodedString()])
    }
    /// Loud enough to count as speech (a 200 Hz tone at about -12 dBFS).
    func speech(seconds: Double) -> Data {
        let samples = (0..<Int(seconds * PCM.sampleRate)).map { Int16(8000 * sin(Double($0) * 2 * .pi * 200 / PCM.sampleRate)) }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    func drop(_ client: PhoneClient, _ page: FakePage) {
        page.task.cancel(with: .goingAway, reason: nil)
        _ = waitFor(2) { client.isAway }
    }
    let second = PCM.bytesPerSecond

    suite("Phone: nothing lost on a bad network") { test in
        test("the reply the phone missed is sent from where it was, a little earlier after a quiet gap") {
            let (phone, port, client, a) = try setUp("resume-gap")
            defer { phone.http.stop() }
            client.session.handle(["type": "response.created", "response": ["id": "r1"]])
            reply(client.session, "i1", bytes: 3 * second)
            expect(waitFor(2) { a.audioBytes == 3 * second }, "the page never got the reply: \(a.audioBytes)")
            expectEqual(a.replies.first?.item, "i1")
            expectEqual(a.replies.first?.at, 0)
            drop(client, a)
            reply(client.session, "i1", bytes: second)  // Ilan goes on while the phone is away
            expect(client.session.remoteHold)
            let b = comeBack(phone, port, "resume-gap", micSent: 0, item: "i1", bytes: 3 * second)
            catchUp(b)
            // It had gone quiet: from 1.5 s before where it was, to the end so far.
            expect(waitFor(2) { b.audioBytes == 4 * second - (3 * second - VoiceSession.resumeRewindBytes) }, "resent \(b.audioBytes)")
            expectEqual(b.replies.first?.item, "i1")
            expectEqual(b.replies.first?.at, 3 * second - VoiceSession.resumeRewindBytes)
            // And the reply carries on live.
            reply(client.session, "i1", bytes: second)
            expect(waitFor(2) { b.audioBytes == 4 * second - (3 * second - VoiceSession.resumeRewindBytes) + second }, "\(b.audioBytes)")
            expect(!client.session.remoteHold)
        }
        test("a phone still playing gets the rest seamlessly: no repeat") {
            let (phone, port, client, a) = try setUp("resume-queued")
            defer { phone.http.stop() }
            client.session.handle(["type": "response.created", "response": ["id": "r1"]])
            reply(client.session, "i1", bytes: 2 * second)
            _ = waitFor(2) { a.audioBytes == 2 * second }
            drop(client, a)
            reply(client.session, "i1", bytes: second)
            let b = comeBack(phone, port, "resume-queued", micSent: 0, item: "i1", bytes: 2 * second, queuedMs: 600)
            catchUp(b)
            expect(waitFor(2) { b.audioBytes == second }, "resent \(b.audioBytes)")
            expectEqual(b.replies.first?.at, 2 * second)
        }
        test("a reply the phone already had in full is not played again; one that started while away is") {
            let (phone, port, client, a) = try setUp("resume-next")
            defer { phone.http.stop() }
            client.session.handle(["type": "response.created", "response": ["id": "r1"]])
            reply(client.session, "i1", bytes: second)
            _ = waitFor(2) { a.audioBytes == second }
            drop(client, a)
            reply(client.session, "i2", bytes: 2 * second)  // the next reply (after a tool call, say) while away
            let b = comeBack(phone, port, "resume-next", micSent: 0, item: "i1", bytes: second)
            catchUp(b)
            expect(waitFor(2) { b.audioBytes == 2 * second }, "resent \(b.audioBytes)")
            expectEqual(b.replies.map(\.item), ["i2"])
            expectEqual(b.replies.first?.at, 0)
        }
        test("nothing missed: nothing is sent again") {
            let (phone, port, client, a) = try setUp("resume-none")
            defer { phone.http.stop() }
            client.session.handle(["type": "response.created", "response": ["id": "r1"]])
            reply(client.session, "i1", bytes: second)
            client.session.handle(["type": "response.done", "response": ["id": "r1", "output": [[String: Any]]()]])
            _ = waitFor(2) { a.audioBytes == second }
            drop(client, a)
            let b = comeBack(phone, port, "resume-none", micSent: 0, item: "i1", bytes: second)
            catchUp(b)
            _ = waitFor(2) { !client.session.remoteHold }
            waitFor(0.2) { false }
            expectEqual(b.audioBytes, 0)
            expect(!client.session.remoteHold)
        }
        test("speech while away comes first: the phone stops, the server learns what was heard, nothing is replayed") {
            let (phone, port, client, a) = try setUp("spoke")
            defer { phone.http.stop() }
            client.session.handle(["type": "response.created", "response": ["id": "r1"]])
            reply(client.session, "i1", bytes: 3 * second)
            _ = waitFor(2) { a.audioBytes == 3 * second }
            drop(client, a)
            reply(client.session, "i1", bytes: second)
            reply(client.session, "i2", bytes: second)
            let words = speech(seconds: 1.5)
            let b = comeBack(phone, port, "spoke", micSent: words.count, item: "i1", bytes: 3 * second, queuedMs: 500)
            expectEqual(b.first("hello_ok")?["micReceived"] as? Int, 0)
            catchUp(b, words)
            expect(waitFor(2) { b.first("audio_stop") != nil }, "the phone was not stopped")
            waitFor(0.2) { false }
            expectEqual(b.audioBytes, 0)
            // Heard: 3 s arrived, 0.5 s of it still unplayed; the later reply not at all.
            expect(client.session.lastRemoteTruncations.map(\.0) == ["i1", "i2"], "\(client.session.lastRemoteTruncations)")
            expect(client.session.lastRemoteTruncations.map(\.1) == [2500, 0], "\(client.session.lastRemoteTruncations)")
            expect(client.session.turnReplies.isEmpty && !client.session.remoteHold)
            expectEqual(client.micReceived, words.count)  // and the words went on to the session
        }
        test("noise while away (scattered loud moments) doesn't count as speech: the reply carries on") {
            let (phone, port, client, a) = try setUp("noise")
            defer { phone.http.stop() }
            client.session.handle(["type": "response.created", "response": ["id": "r1"]])
            reply(client.session, "i1", bytes: 2 * second)
            _ = waitFor(2) { a.audioBytes == 2 * second }
            drop(client, a)
            // 10 s with a loud 0.1 s bump every second: 50 loud frames in all, but never 40 within 3 s.
            var noise = Data()
            for _ in 0..<10 { noise.append(speech(seconds: 0.1)); noise.append(Data(count: Int(0.9 * Double(second)))) }
            let b = comeBack(phone, port, "noise", micSent: noise.count, item: "i1", bytes: 2 * second, queuedMs: 300)
            catchUp(b, noise)
            reply(client.session, "i1", bytes: second)
            expect(waitFor(2) { b.audioBytes == second }, "the reply did not carry on: \(b.audioBytes)")
            expect(b.first("audio_stop") == nil)
        }
        test("back before the Mac noticed the drop: still sent what it missed") {
            let (phone, port, client, a) = try setUp("unnoticed")
            defer { phone.http.stop() }
            client.session.handle(["type": "response.created", "response": ["id": "r1"]])
            reply(client.session, "i1", bytes: 2 * second)
            _ = waitFor(2) { a.audioBytes == 2 * second }
            // The page's connection died silently after 1 s of the reply; it reconnects at once.
            let b = comeBack(phone, port, "unnoticed", micSent: 0, item: "i1", bytes: second, queuedMs: 0)
            expect(waitFor(2) { a.first("replaced") != nil }, "the old connection was not replaced")
            expect(client.session.remoteHold, "the reply should wait for the catch-up")
            catchUp(b)
            // It had heard 1 s and gone quiet: the rewind goes back to the start of the reply.
            expect(waitFor(2) { b.audioBytes == 2 * second }, "resent \(b.audioBytes)")
            expectEqual(b.replies.first?.at, 0)
        }
        test("the microphone is counted: a page back sends only what the Mac missed") {
            let (phone, port, client, a) = try setUp("mic")
            defer { phone.http.stop() }
            a.sendAudio(Data(count: 9_600))
            expect(waitFor(2) { client.micReceived == 9_600 }, "\(client.micReceived)")
            drop(client, a)
            let b = comeBack(phone, port, "mic", micSent: 19_200, item: nil, bytes: 0)
            expectEqual(b.first("hello_ok")?["micReceived"] as? Int, 9_600)
            catchUp(b, Data(count: 9_600))
            expect(waitFor(2) { client.micReceived == 19_200 }, "\(client.micReceived)")
        }
        test("a catch-up cut short by another drop isn't counted, so it is sent again") {
            let (phone, port, client, a) = try setUp("cut-catchup")
            defer { phone.http.stop() }
            drop(client, a)
            let b = comeBack(phone, port, "cut-catchup", micSent: 9_600, item: nil, bytes: 0)
            b.say(["type": "catchup", "bytes": 9_600, "lost": 0])
            b.sendAudio(Data(count: 4_800))
            waitFor(0.1) { false }
            drop(client, b)
            expectEqual(client.micReceived, 0)
            let c = comeBack(phone, port, "cut-catchup", micSent: 9_600, item: nil, bytes: 0)
            expectEqual(c.first("hello_ok")?["micReceived"] as? Int, 0)
            catchUp(c, Data(count: 9_600))
            expect(waitFor(2) { client.micReceived == 9_600 })
        }
        test("a page that never sends its catch-up: the reply carries on after a while") {
            let saved = PhoneClient.catchUpTimeout
            PhoneClient.catchUpTimeout = 0.2
            defer { PhoneClient.catchUpTimeout = saved }
            let (phone, port, client, a) = try setUp("no-catchup")
            defer { phone.http.stop() }
            client.session.handle(["type": "response.created", "response": ["id": "r1"]])
            reply(client.session, "i1", bytes: 2 * second)
            _ = waitFor(2) { a.audioBytes == 2 * second }
            drop(client, a)
            let b = comeBack(phone, port, "no-catchup", micSent: 0, item: "i1", bytes: 2 * second, queuedMs: 400)
            expect(client.session.remoteHold)
            reply(client.session, "i1", bytes: second)
            expect(waitFor(2) { b.audioBytes == second }, "the reply never carried on: \(b.audioBytes)")
        }
        test("a phone still playing a reply the Mac let go of (its stop was lost) is stopped") {
            let (phone, port, client, a) = try setUp("stale")
            defer { phone.http.stop() }
            drop(client, a)
            let b = comeBack(phone, port, "stale", micSent: 0, item: "old", bytes: 9_600, queuedMs: 500)
            catchUp(b)
            expect(waitFor(2) { b.first("audio_stop") != nil }, "the stale reply was not stopped")
        }
        test("a slow catch-up gets its time: the wait restarts with each piece") {
            let saved = PhoneClient.catchUpTimeout
            PhoneClient.catchUpTimeout = 0.15
            defer { PhoneClient.catchUpTimeout = saved }
            let (phone, port, client, a) = try setUp("slow-catchup")
            defer { phone.http.stop() }
            drop(client, a)
            let words = speech(seconds: 1.5)
            let b = comeBack(phone, port, "slow-catchup", micSent: words.count, item: nil, bytes: 0)
            b.say(["type": "catchup", "bytes": words.count, "lost": 0])
            // Three pieces, 0.1 s apart: 0.3 s in all, past the 0.15 s wait, but never 0.15 s without a piece.
            for i in 0..<3 {
                b.sendAudio(words.subdata(in: i * words.count / 3..<(i + 1) * words.count / 3))
                waitFor(0.1) { false }
            }
            b.say(["type": "catchup_end"])
            let events = { ((try? String(contentsOf: PhoneClient.connectionLog, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .filter { $0["device"] as? String == "slow-catchup" && $0["event"] as? String == "caught up" } }
            expect(waitFor(2) { !events().isEmpty })
            expectEqual(events().last?["timedOut"] as? Bool, false)
            expectEqual(events().last?["spoke"] as? Bool, true)
        }
        test("the connection log has the catch-up: how long, whether the user spoke") {
            try? FileManager.default.removeItem(at: PhoneClient.connectionLog)
            let (phone, port, client, a) = try setUp("log-catchup")
            defer { phone.http.stop() }
            drop(client, a)
            let b = comeBack(phone, port, "log-catchup", micSent: 2 * second, item: nil, bytes: 0)
            catchUp(b, speech(seconds: 2))
            let events = { ((try? String(contentsOf: PhoneClient.connectionLog, encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .filter { $0["device"] as? String == "log-catchup" && $0["event"] as? String == "caught up" } }
            expect(waitFor(2) { !events().isEmpty })
            expectEqual(events().first?["spoke"] as? Bool, true)
            expectEqual(events().first?["seconds"] as? Double, 2)
        }
    }
}
