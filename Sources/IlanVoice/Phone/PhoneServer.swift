import AppKit
import Combine
import CoreImage
import Foundation

/// "Start Web Server": serves the iPhone web app and connects it to a voice
/// session of its own, which talks in the iPhone's conversation with the same
/// agent.md, tools and settings as the Mac.
///
/// The server listens on 127.0.0.1 only. Tailscale Serve publishes it on this
/// Mac's tailnet name over HTTPS (iPhones only allow the microphone on HTTPS
/// pages), so it is reachable from your own devices and nowhere else. A pairing
/// code in the link keeps other devices on the tailnet out.
@MainActor
final class PhoneServer: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case running(url: String)
        case failed(String)
    }

    static let localPort: UInt16 = 47_823
    static let httpsPort = 8767
    private static let tokenName = "ILAN_VOICE_PHONE_TOKEN"

    @Published private(set) var status: Status = .stopped
    @Published private(set) var phoneConnected = false

    let session: VoiceSession
    private let store: ConversationStore
    private let input = RemoteMicrophone()
    private let output = RemoteSpeaker()
    private let http = MiniHTTPServer()
    private var peer: WebSocketPeer?
    /// Connections that haven't sent the pairing code yet; held so they stay alive.
    private var pending: [ObjectIdentifier: WebSocketPeer] = [:]
    private var conversationID: UUID?
    private var cancellables: Set<AnyCancellable> = []
    private var lastSentMessages: [[String: Any]] = []

    init(store: ConversationStore, mcp: MCPManager) {
        self.store = store
        var target: (() -> UUID?)?
        session = VoiceSession(store: store, mcp: mcp, input: input, output: output, isRemote: true,
                               target: { target?() })
        target = { [weak self] in self?.currentConversation() }

        output.sendAudio = { [weak self] pcm in self?.peer?.send(binary: pcm) }
        output.sendStop = { [weak self] in self?.peer?.send(json: ["type": "audio_stop"]) }
        http.route = { Self.file(for: $0) }
        http.onSocket = { [weak self] in self?.adopt($0) }

        session.$phase.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sendState() } }
            .store(in: &cancellables)
        session.$errorMessage.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sendState() } }
            .store(in: &cancellables)
        store.$conversations
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.sendMessages() }
            .store(in: &cancellables)
    }

    // MARK: Pairing

    /// The secret in the link; without it the phone can't talk to the server.
    var token: String {
        if let t = SecretStore.get(Self.tokenName), !t.isEmpty { return t }
        let t = Self.newToken()
        SecretStore.set(Self.tokenName, t)
        return t
    }

    /// Makes old links (and phones paired with them) stop working.
    func resetPairing() {
        SecretStore.set(Self.tokenName, Self.newToken())
        peer?.close()
        if case .running = status { Task { await refreshURL() } }
    }

    private static func newToken() -> String {
        (0..<24).map { _ in String("abcdefghijkmnpqrstuvwxyz23456789".randomElement()!) }.joined()
    }

    /// The link to open on the iPhone, pairing code included.
    var pairingURL: String? {
        guard case .running(let url) = status else { return nil }
        return url
    }

    // MARK: Start / stop

    func start() {
        switch status {
        case .starting, .running: return
        default: break
        }
        status = .starting
        AppSettings.shared.phoneServerEnabled = true
        do {
            try http.start(port: Self.localPort)
        } catch {
            status = .failed("Couldn't open port \(Self.localPort): \(error.localizedDescription)")
            return
        }
        Task {
            if let problem = await Tailscale.serve(httpsPort: Self.httpsPort, to: Self.localPort) {
                http.stop()
                status = .failed(problem)
                return
            }
            await refreshURL()
        }
    }

    func stop() {
        AppSettings.shared.phoneServerEnabled = false
        peer?.close()
        peer = nil
        phoneConnected = false
        session.disconnect()
        http.stop()
        status = .stopped
        Task { await Tailscale.stopServing(httpsPort: Self.httpsPort) }
    }

    private func refreshURL() async {
        guard let host = await Tailscale.dnsName() else {
            status = .failed("Couldn't read this Mac's Tailscale name. Is Tailscale running and signed in?")
            return
        }
        status = .running(url: "https://\(host):\(Self.httpsPort)/?t=\(token)")
    }

    // MARK: The phone's connection

    private func adopt(_ newPeer: WebSocketPeer) {
        var authorised = false
        let key = ObjectIdentifier(newPeer)
        pending[key] = newPeer
        newPeer.onText = { [weak self, weak newPeer] text in
            guard let self, let newPeer,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let type = obj["type"] as? String else { return }
            if !authorised {
                guard type == "hello", (obj["token"] as? String) == self.token else {
                    newPeer.send(json: ["type": "auth_failed"])
                    newPeer.close()
                    return
                }
                authorised = true
                self.pending[key] = nil
                self.connected(newPeer)
                return
            }
            self.command(type)
        }
        newPeer.onBinary = { [weak self, weak newPeer] data in
            guard authorised, let self, newPeer === self.peer else { return }
            self.input.deliver(data)
        }
        newPeer.onClose = { [weak self, weak newPeer] in
            guard let self else { return }
            self.pending[key] = nil
            guard newPeer === self.peer else { return }
            self.peer = nil
            self.phoneConnected = false
            if self.session.phase == .recording { self.session.releaseToTalk() }
        }
    }

    /// Only one phone at a time: a new one replaces the old.
    private func connected(_ newPeer: WebSocketPeer) {
        if let old = peer, old !== newPeer { old.close() }
        peer = newPeer
        phoneConnected = true
        lastSentMessages = []
        newPeer.send(json: ["type": "hello_ok"])
        sendMessages()
        sendState()
        if session.phase == .offline { session.connect() }
    }

    private func command(_ type: String) {
        switch type {
        case "press": session.pressToTalk()
        case "release": session.releaseToTalk()
        case "stop": session.interrupt()
        case "replay": replayLast()
        default: break
        }
    }

    /// The iPhone's conversation, created on first use. Deleting it on the Mac
    /// just means the next press starts a fresh one.
    private func currentConversation() -> UUID {
        if let id = conversationID, store.conversations.contains(where: { $0.id == id }) { return id }
        let id = store.iPhoneConversation()
        conversationID = id
        return id
    }

    /// Plays Ilan's latest reply again on the phone.
    private func replayLast() {
        let convID = currentConversation()
        guard let conv = store.conversations.first(where: { $0.id == convID }),
              let last = conv.messages.last(where: { $0.role == .assistant && $0.audioFile != nil }),
              let wav = try? Data(contentsOf: store.audioURL(convID, last.audioFile!)), wav.count > 44 else { return }
        session.interrupt()
        peer?.send(json: ["type": "audio_stop"])
        let pcm = wav.dropFirst(44)
        let chunk = 48_000  // half a second
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            let end = min(offset + chunk, pcm.endIndex)
            peer?.send(binary: Data(pcm[offset..<end]))
            offset = end
        }
    }

    private func sendState() {
        guard let peer else { return }
        var state: [String: Any] = ["type": "state", "phase": session.phase.label, "busy": session.phase != .ready && session.phase != .offline]
        if let error = session.errorMessage { state["error"] = error }
        peer.send(json: state)
    }

    private func sendMessages() {
        guard let peer, let convID = conversationID ?? store.conversations.first(where: \.isFromIPhone)?.id,
              let conv = store.conversations.first(where: { $0.id == convID }) else { return }
        let items: [[String: Any]] = conv.messages.suffix(80).compactMap { m in
            switch m.role {
            case .user, .assistant:
                return ["id": m.id, "role": m.role == .user ? "user" : "assistant", "text": m.text, "pending": m.pending]
            case .tool:
                return ["id": m.id, "role": "tool", "text": m.toolName ?? "tool", "pending": m.pending]
            }
        }
        guard !NSArray(array: items).isEqual(to: lastSentMessages) else { return }
        lastSentMessages = items
        peer.send(json: ["type": "messages", "title": conv.title, "items": items])
    }

    // MARK: Files

    private static func file(for path: String) -> MiniHTTPServer.Response? {
        switch path {
        case "/", "/index.html":
            return .init(contentType: "text/html; charset=utf-8", body: Data(PhoneWebApp.html.utf8))
        case "/manifest.webmanifest":
            return .init(contentType: "application/manifest+json", body: Data(PhoneWebApp.manifest.utf8))
        case "/icon-180.png": return icon(180)
        case "/icon-512.png": return icon(512)
        default: return nil
        }
    }

    private static func icon(_ size: Int) -> MiniHTTPServer.Response? {
        let source = NSApp.applicationIconImage ?? NSImage()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return .init(contentType: "image/png", body: png)
    }

    /// A QR code for the pairing link, to scan with the iPhone camera.
    static func qrCode(for text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The few `tailscale` commands the server needs.
enum Tailscale {
    private static let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                                     "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]

    private static var binary: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// Publishes 127.0.0.1:`port` at https://<this Mac>:`httpsPort` on the
    /// tailnet. Returns a problem to show, or nil on success.
    static func serve(httpsPort: Int, to port: UInt16) async -> String? {
        guard binary != nil else { return "Tailscale isn't installed on this Mac." }
        let result = await run(["serve", "--bg", "--https=\(httpsPort)", "http://127.0.0.1:\(port)"])
        return result.status == 0 ? nil : "Tailscale couldn't publish the server: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    static func stopServing(httpsPort: Int) async {
        _ = await run(["serve", "--https=\(httpsPort)", "off"])
    }

    /// This Mac's name on the tailnet, e.g. my-mac.tail1234.ts.net.
    static func dnsName() async -> String? {
        let result = await run(["status", "--json"])
        guard result.status == 0,
              let obj = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any],
              let me = obj["Self"] as? [String: Any], var name = me["DNSName"] as? String, !name.isEmpty else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    private static func run(_ args: [String]) async -> (status: Int32, output: String) {
        guard let binary else { return (-1, "") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = args
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                }
            }
        }
    }
}
