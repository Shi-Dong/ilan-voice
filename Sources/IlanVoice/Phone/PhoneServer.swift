import AppKit
import Combine
import CoreImage
import Foundation

/// "Start Web Server": serves the iPhone web app. Each iPhone gets a voice
/// session and a conversation of its own (see PhoneClient), with the same
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
    private static let devicesKey = "phoneDeviceNumbers"

    @Published private(set) var status: Status = .stopped
    /// How many iPhones are connected right now.
    @Published private(set) var connectedCount = 0

    private let store: ConversationStore
    private let mcp: MCPManager
    private let http = MiniHTTPServer()
    /// One client per iPhone, by the device ID the page keeps in its storage.
    private var clients: [String: PhoneClient] = [:]
    /// Connections that haven't sent the pairing code yet; held so they stay alive.
    private var pending: [ObjectIdentifier: WebSocketPeer] = [:]

    init(store: ConversationStore, mcp: MCPManager) {
        self.store = store
        self.mcp = mcp
        http.route = { Self.file(for: $0) }
        http.onSocket = { [weak self] in self?.adopt($0) }
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
        clients.values.forEach { $0.disconnect() }
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

    /// "iPhone 1", "iPhone 2", … in the order the phones first connected.
    static func number(for device: String) -> Int {
        let defaults = UserDefaults.standard
        var numbers = defaults.dictionary(forKey: devicesKey) as? [String: Int] ?? [:]
        if let n = numbers[device] { return n }
        let n = (numbers.values.max() ?? 0) + 1
        numbers[device] = n
        defaults.set(numbers, forKey: devicesKey)
        return n
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
        clients.values.forEach { $0.shutDown() }
        clients = [:]
        connectedCount = 0
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

    // MARK: Connections

    private func adopt(_ peer: WebSocketPeer) {
        let key = ObjectIdentifier(peer)
        pending[key] = peer
        peer.onClose = { [weak self] in self?.pending[key] = nil }
        peer.onText = { [weak self, weak peer] text in
            guard let self, let peer,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
            self.pending[key] = nil
            guard obj["type"] as? String == "hello", (obj["token"] as? String) == self.token,
                  let device = obj["device"] as? String, !device.isEmpty, device.count <= 64 else {
                peer.send(json: ["type": "auth_failed"])
                peer.close()
                return
            }
            let client = self.clients[device] ?? {
                let c = PhoneClient(device: device, store: self.store, mcp: self.mcp)
                c.onConnectionChange = { [weak self] in self?.recount() }
                self.clients[device] = c
                return c
            }()
            client.attach(peer)
            // A page this Mac hasn't seen (new phone, or the home-screen app
            // removed and added again) is asked which iPhone it is, so a
            // re-added app can carry on with its old conversation.
            if !Self.isKnown(device) {
                let phones = self.knownPhones()
                if phones.isEmpty { _ = Self.number(for: device) } else {
                    peer.send(json: ["type": "choose_phone", "phones": phones])
                }
            }
        }
    }

    static func isKnown(_ device: String) -> Bool {
        (UserDefaults.standard.dictionary(forKey: devicesKey) as? [String: Int])?[device] != nil
    }

    /// The iPhones seen before, newest conversation first, for the page's
    /// "Which iPhone is this?" sheet.
    private func knownPhones() -> [[String: Any]] {
        let numbers = UserDefaults.standard.dictionary(forKey: Self.devicesKey) as? [String: Int] ?? [:]
        let formatter = RelativeDateTimeFormatter()
        return numbers.map { device, n -> (Date, [String: Any]) in
            let conv = store.conversations.filter { $0.isFromIPhone && $0.deviceID == device }
                .max { $0.updatedAt < $1.updatedAt }
            var phone: [String: Any] = ["device": device, "name": "iPhone \(n)"]
            if let conv {
                phone["title"] = conv.title
                phone["when"] = formatter.localizedString(for: conv.updatedAt, relativeTo: Date())
            }
            return (conv?.updatedAt ?? .distantPast, phone)
        }
        .sorted { $0.0 > $1.0 }
        .map(\.1)
    }

    private func recount() {
        connectedCount = clients.values.filter(\.isConnected).count
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

    /// The app icon with a voice badge in the lower right, so the iPhone web
    /// app is told apart from other Ilan icons on the home screen.
    private static func icon(_ size: Int) -> MiniHTTPServer.Response? {
        // The square artwork itself, not the Mac's rounded icon (iOS rounds it).
        let source = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
            ?? NSApp.applicationIconImage ?? NSImage()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(size)
        source.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
        // Badge: a dark disc with a light ring, inset from the corner so iOS's
        // rounded mask doesn't clip it.
        let d = s * 0.42
        let badge = NSRect(x: s - d - s * 0.07, y: s * 0.07, width: d, height: d)
        NSColor(red: 0.055, green: 0.071, blue: 0.075, alpha: 1).setFill()
        NSBezierPath(ovalIn: badge).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: badge.insetBy(dx: s * 0.012, dy: s * 0.012))
        ring.lineWidth = s * 0.024
        ring.stroke()
        // Five voice bars, like the listening pill.
        NSColor(red: 0.663, green: 0.863, blue: 0.796, alpha: 1).setFill()
        let heights: [CGFloat] = [0.30, 0.58, 0.82, 0.58, 0.30]
        let barW = d * 0.085, gap = d * 0.06
        let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
        var x = badge.midX - total / 2
        for h in heights {
            let barH = d * 0.62 * h
            NSBezierPath(roundedRect: NSRect(x: x, y: badge.midY - barH / 2, width: barW, height: barH),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }
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
