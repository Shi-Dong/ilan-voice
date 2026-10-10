import Foundation
@testable import IlanVoice

// The iPhone web app: the local web server and its WebSocket framing, pairing,
// the audio bridge, and a syntax check of the page's JavaScript. The server
// runs for real on a spare 127.0.0.1 port; Tailscale is never involved.

/// Holds what a background URLSession callback hands back.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// Keeps the main run loop turning (the server lives on it) until `done`.
@MainActor
@discardableResult
func waitFor(_ seconds: Double = 3, _ done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    return done()
}

/// Starts `server` on a free port and returns it.
@MainActor
func startOnSparePort(_ server: MiniHTTPServer) throws -> UInt16 {
    var lastError: Error?
    for _ in 0..<20 {
        let port = UInt16.random(in: 50_000...60_000)
        do { try server.start(port: port); return port } catch { lastError = error }
    }
    throw lastError ?? URLError(.cannotConnectToHost)
}

@MainActor
func get(_ url: URL) -> (status: Int, type: String, body: Data)? {
    let box = Box<(Int, String, Data)?>(nil)
    URLSession.shared.dataTask(with: url) { data, response, _ in
        let http = response as? HTTPURLResponse
        box.value = (http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "Content-Type") ?? "", data ?? Data())
    }.resume()
    waitFor { box.value != nil }
    return box.value
}

/// Receives one WebSocket message, keeping the run loop going meanwhile.
@MainActor
func receive(_ task: URLSessionWebSocketTask) -> URLSessionWebSocketTask.Message? {
    let box = Box<URLSessionWebSocketTask.Message?>(nil)
    task.receive { if case .success(let m) = $0 { box.value = m } }
    waitFor { box.value != nil }
    return box.value
}

@MainActor
func send(_ task: URLSessionWebSocketTask, _ message: URLSessionWebSocketTask.Message) {
    let sent = Box(false)
    task.send(message) { _ in sent.value = true }
    waitFor { sent.value }
}

func json(_ message: URLSessionWebSocketTask.Message?) -> [String: Any] {
    guard case .string(let text)? = message else { return [:] }
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

@MainActor
func registerPhoneTests() {
    suite("Phone web server") { test in
        test("the page stays below the iPhone status bar (no blurred top edge)") {
            let html = PhoneWebApp.html
            expect(html.contains(#"name="apple-mobile-web-app-status-bar-style" content="black">"#), "status bar should be opaque")
            expect(!html.contains("black-translucent"), "a translucent status bar puts the page under iOS's blur")
        }
        test("serves the page, manifest and icons; unknown paths are 404") {
            let server = MiniHTTPServer()
            server.route = { PhoneServer.file(for: $0) }
            let port = try startOnSparePort(server)
            defer { server.stop() }
            let base = "http://127.0.0.1:\(port)"

            let page = get(URL(string: base + "/?t=abc")!)
            expectEqual(page?.status, 200)
            expect(page?.type.hasPrefix("text/html") == true, page?.type ?? "")
            expect(String(decoding: page?.body ?? Data(), as: UTF8.self).contains("<script>"))

            let manifest = get(URL(string: base + "/manifest.webmanifest")!)
            expectEqual(manifest?.status, 200)
            expect((try? JSONSerialization.jsonObject(with: manifest?.body ?? Data())) != nil, "manifest is not JSON")

            let icon = get(URL(string: base + "/icon-180.png")!)
            expectEqual(icon?.status, 200)
            expect(icon?.body.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true, "not a PNG")

            expectEqual(get(URL(string: base + "/secrets.json")!)?.status, 404)
        }

        test("WebSocket frames of every length survive both directions") {
            let server = MiniHTTPServer()
            var peers: [WebSocketPeer] = []
            server.onSocket = { peer in
                peers.append(peer)
                peer.onText = { [weak peer] in peer?.send(text: "echo:" + $0) }
                peer.onBinary = { [weak peer] in peer?.send(binary: $0) }
            }
            let port = try startOnSparePort(server)
            defer { server.stop() }
            let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
            task.resume()
            defer { task.cancel(with: .goingAway, reason: nil) }

            // 7-bit, 16-bit and 64-bit length encodings; the browser masks, the server doesn't.
            for size in [5, 300, 70_000] {
                let text = String(repeating: "a", count: size)
                send(task, .string(text))
                if case .string(let reply)? = receive(task) { expectEqual(reply, "echo:" + text) } else { expect(false, "no text reply for \(size)") }
                let bytes = Data((0..<size).map { UInt8($0 % 251) })
                send(task, .data(bytes))
                if case .data(let reply)? = receive(task) { expectEqual(reply, bytes) } else { expect(false, "no binary reply for \(size)") }
            }
            expectEqual(peers.count, 1)
        }
    }

    suite("Phone pairing") { test in
        test("a wrong pairing code is refused, the right one is accepted") {
            let phone = PhoneServer(store: ConversationStore(), mcp: MCPManager())
            let port = try startOnSparePort(phone.http)
            defer { phone.http.stop() }
            let url = URL(string: "ws://127.0.0.1:\(port)/ws")!

            let intruder = URLSession.shared.webSocketTask(with: url)
            intruder.resume()
            send(intruder, .string(#"{"type":"hello","token":"wrong","device":"d1"}"#))
            expectEqual(json(receive(intruder))["type"] as? String, "auth_failed")
            intruder.cancel(with: .goingAway, reason: nil)

            let owner = URLSession.shared.webSocketTask(with: url)
            owner.resume()
            let hello = try JSONSerialization.data(withJSONObject: ["type": "hello", "token": phone.token, "device": "test-phone"])
            send(owner, .string(String(decoding: hello, as: UTF8.self)))
            expectEqual(json(receive(owner))["type"] as? String, "hello_ok")
            owner.cancel(with: .goingAway, reason: nil)
            waitFor(0.2) { false }  // let the server see the close
        }

        test("each iPhone keeps a stable number") {
            let a = "phone-a-\(UUID().uuidString)", b = "phone-b-\(UUID().uuidString)"
            expect(!PhoneServer.isKnown(a))
            let first = PhoneServer.number(for: a)
            expectEqual(PhoneServer.number(for: a), first)
            expectEqual(PhoneServer.number(for: b), first + 1)
            expect(PhoneServer.isKnown(a) && PhoneServer.isKnown(b))
        }
    }

    suite("Phone audio") { test in
        test("the iPhone microphone only passes audio on while recording") {
            let mic = RemoteMicrophone()
            var levels: [Float] = []
            mic.onChunk = { _, level in levels.append(level) }
            let loud = [Int16](repeating: 16_000, count: 480).withUnsafeBufferPointer { Data(buffer: $0) }
            mic.deliver(loud)
            expect(levels.isEmpty, "delivered while not recording")
            try mic.start()
            mic.deliver(Data(count: 960))
            mic.deliver(loud)
            mic.stop()
            mic.deliver(loud)
            expectEqual(levels.count, 2)
            expectEqual(levels.first, 0)
            expectEqual(levels.last, 1)  // clipped to 1
        }

        test("the iPhone speaker forwards audio and stops only while playing") {
            let speaker = RemoteSpeaker()
            var sent = 0, stops = 0
            speaker.sendAudio = { sent += $0.count }
            speaker.sendStop = { stops += 1 }
            speaker.stop()
            expectEqual(stops, 0)
            speaker.enqueue(Data(count: 48_000))  // 1 s
            expectEqual(sent, 48_000)
            expectEqual(speaker.enqueuedFrames, 24_000)
            expect(speaker.isPlaying)
            speaker.stop()
            expectEqual(stops, 1)
            expect(!speaker.isPlaying)
        }

        test("the prebuffer matches the web page") {
            expect(PhoneWebApp.html.contains("PREBUFFER = \(RemoteSpeaker.prebufferSeconds)"),
                   "RemoteSpeaker.prebufferSeconds and PREBUFFER in the page differ")
        }
    }

    suite("Phone web page") { test in
        test("the page's JavaScript parses (needs Node.js; skipped without it)") {
            let html = PhoneWebApp.html
            guard let open = html.range(of: "<script>"), let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else {
                expect(false, "no <script> in the page"); return
            }
            let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            guard let node = (path + ["/opt/homebrew/bin", "/usr/local/bin"]).map({ $0 + "/node" })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                print("  (skipped: Node.js not installed)"); return
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ilan-voice-page-\(UUID().uuidString).js")
            try String(html[open.upperBound..<close.lowerBound]).write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = ["--check", file.path]
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            expectEqual(process.terminationStatus, 0)
            if process.terminationStatus != 0 {
                print(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
        }
    }
}
