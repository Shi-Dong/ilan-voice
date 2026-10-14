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
        test("the page sits below an opaque status bar and does not ask to extend under it") {
            let html = PhoneWebApp.html
            // viewport-fit=cover made iOS draw the page from the top while sizing it
            // a status bar short: a black band at the bottom, outside the page.
            expect(html.contains(#"<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">"#),
                   "the viewport must not use viewport-fit=cover")
            expect(html.contains(#"name="apple-mobile-web-app-status-bar-style" content="black">"#), "status bar should be opaque")
        }
        test("a page shorter than the screen drops the home-bar spacing under the footer") {
            let html = PhoneWebApp.html
            expect(html.contains("html.short-page footer { bottom: 8px; }"))
            expect(html.contains(#"classList.toggle("short-page", gap > 30)"#))
        }
        test("the conversation title has room above its letters (no clipped top)") {
            let html = PhoneWebApp.html
            guard let rule = html.range(of: "header .title {") else { return expect(false, "title rule missing") }
            let css = String(html[rule.lowerBound...].prefix(240))
            expect(css.contains("line-height: 24px"), "title needs a whole-pixel line height")
            expect(css.contains("padding: 2px 0"), "title needs padding so overflow: hidden never cuts the letters")
        }
        test("the page has a Reconnect button that asks the Mac for a fresh session") {
            let html = PhoneWebApp.html
            expect(html.contains(#"<button id="reconnect""#), "reconnect button missing")
            expect(html.contains(#"send({ type: "reconnect" })"#), "reconnect button should send a reconnect command")
            expect(!html.contains(#"id="replay""#), "the replay button was removed")
        }
        test("the page uses Liquid Glass: blurred, floating header and footer") {
            let html = PhoneWebApp.html
            expect(html.contains("---- Liquid Glass ----"), "glass layer missing")
            expect(html.contains("backdrop-filter: var(--glass-blur)"), "glass surfaces need a backdrop blur")
            expect(html.contains("header { position: fixed;") && html.contains("footer { position: fixed;"),
                   "header and footer should float over the conversation")
            expect(html.contains("--head-h") && html.contains("--foot-h"), "the list must be padded by the bars' real heights")
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

        test("costs and token counts reach the page only while the Mac shows them") {
            let settings = AppSettings.shared
            let before = settings.showUsage
            defer { settings.showUsage = before }
            settings.showUsage = true
            let store = ConversationStore()
            let phone = PhoneServer(store: store, mcp: MCPManager())
            let conv = store.iPhoneConversation(device: "usage-phone", create: true)!
            let tokens = TokenUsage(textInput: 1200, audioInput: 800, cachedTextInput: 1000, textOutput: 50, audioOutput: 400)
            store.update(conv) {
                var reply = Message(id: "r1", role: .assistant, text: "Hello")
                reply.usage = tokens
                $0.messages.append(reply)
            }
            store.recordUsage(conv, UsageRecord(model: "gpt-realtime-2.1", tokens: tokens))
            let port = try startOnSparePort(phone.http)
            defer { phone.http.stop() }
            let ws = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
            ws.resume()
            defer { ws.cancel(with: .goingAway, reason: nil) }
            let hello = try JSONSerialization.data(withJSONObject: ["type": "hello", "token": phone.token, "device": "usage-phone"])
            send(ws, .string(String(decoding: hello, as: UTF8.self)))
            @MainActor func nextMessages() -> [String: Any] {
                for _ in 0..<8 { let m = json(receive(ws)); if m["type"] as? String == "messages" { return m } }
                return [:]
            }
            let shown = nextMessages()
            let reply = (shown["items"] as? [[String: Any]])?.first { $0["id"] as? String == "r1" }
            expectEqual(reply?["usage"] as? String, Pricing.describe(tokens))
            expect((shown["cost"] as? String)?.hasPrefix("$") == true, "conversation cost missing: \(shown)")

            settings.showUsage = false
            let hidden = nextMessages()
            let plain = (hidden["items"] as? [[String: Any]])?.first { $0["id"] as? String == "r1" }
            expect(plain != nil && plain?["usage"] == nil, "token counts should be hidden")
            expect(hidden["cost"] == nil, "cost should be hidden")
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
        test("no hard line under the status bar: messages fade out, and the bar melts into the page") {
            let html = PhoneWebApp.html
            expect(html.contains("mask-image: linear-gradient(to bottom, transparent 0, #000 56px)"), "messages aren't faded at the top")
            expect(html.contains("background: linear-gradient(to bottom, #000, rgba(0,0,0,0))"), "no soft band under the status bar")
        }
        test("pocket mode: screen on, only a full push up the track ends; then audio and screen are let go (needs Node.js)") {
            let html = PhoneWebApp.html
            guard let open = html.range(of: "<script>"), let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) else {
                expect(false, "no <script> in the page"); return
            }
            let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            guard let node = (path + ["/opt/homebrew/bin", "/usr/local/bin"]).map({ $0 + "/node" })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                print("  (skipped: Node.js not installed)"); return
            }
            // page-audio-harness.js runs the page with fake browser objects and
            // reports the iOS audio session and open audio contexts.
            let harness = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("page-audio-harness.js")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ilan-voice-page-\(UUID().uuidString).js")
            try String(html[open.upperBound..<close.lowerBound]).write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [harness.path, file.path]
            let out = Pipe(), errors = Pipe()
            process.standardOutput = out
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0,
                  let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                expect(false, "harness failed: " + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
                return
            }
            let during = json["during"] as? [String: Any], after = json["after"] as? [String: Any]
            expectEqual(json["atLoad"] as? String, "auto")              // no claim before a conversation
            expectEqual(during?["session"] as? String, "play-and-record")
            expectEqual(during?["screenKeptOn"] as? Bool, true)         // auto-lock would end the conversation
            expectEqual(after?["screenKeptOn"] as? Bool, false)         // Auto-Lock works again afterwards
            // A home-screen page shorter than the screen: the shortfall is measured,
            // applied (background stretched, footer moved down), and reported to the Mac.
            let viewport = json["viewport"] as? [String: Any]
            expectEqual(viewport?["gap"] as? Int, 62)
            expectEqual(json["shortPage"] as? Bool, true)  // footer drops its home-bar spacing
            expectEqual(viewport?["innerHeight"] as? Int, 790)
            expectEqual(viewport?["safeTop"] as? Int, 62)
            // Ilan ended it by voice: the page ends too, with the closing sound, without echoing a stop.
            let byIlan = json["endedByIlan"] as? [String: Any]
            expectEqual(byIlan?["sentStop"] as? Bool, false)
            expectEqual(byIlan?["chimed"] as? Bool, true)
            expectEqual(byIlan?["session"] as? String, "auto")
            expectEqual(byIlan?["screenKeptOn"] as? Bool, false)
            // Pocket mode: only pushing the button all the way up the track ends it (no holding).
            let pocket = json["pocket"] as? [String: Any]
            expectEqual(pocket?["afterStrayTap"] as? Bool, true)        // still on
            expectEqual(pocket?["afterShortPush"] as? Bool, true)
            expectEqual(pocket?["afterSmallPush"] as? Bool, true)
            expectEqual(pocket?["afterDrift"] as? Bool, true)
            expectEqual(pocket?["afterEndGesture"] as? Bool, false)     // ended
            expectEqual(after?["session"] as? String, "auto")           // let go afterwards…
            expectEqual(after?["openContexts"] as? Int, 0)              // …and nothing left running (no Now Playing)
        }
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

/// The page's viewport reports end up in a log the Mac keeps, for diagnosing
/// iOS layout bugs on a phone we can't look at.
@MainActor
func registerViewportLogTests() {
    suite("Phone viewport log") { test in
        test("a report from the page is appended to phone-viewport.log with time and device") {
            try? FileManager.default.removeItem(at: PhoneClient.viewportLog)
            let store = ConversationStore()
            let client = PhoneClient(device: "test-phone", store: store, mcp: MCPManager())
            client.receiveForTesting(#"{"type":"viewport","innerHeight":790,"screenHeight":852,"gap":62}"#)
            client.receiveForTesting(#"{"type":"viewport","innerHeight":852,"screenHeight":852,"gap":0}"#)
            let lines = (try? String(contentsOf: PhoneClient.viewportLog, encoding: .utf8))?.split(separator: "\n") ?? []
            expectEqual(lines.count, 2)
            let first = (try? JSONSerialization.jsonObject(with: Data((lines.first ?? "").utf8))) as? [String: Any]
            expectEqual(first?["gap"] as? Int, 62)
            expectEqual(first?["device"] as? String, "test-phone")
            expect(first?["time"] != nil)
        }
    }
}
