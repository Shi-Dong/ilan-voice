import CryptoKit
import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 that serves a few fixed files and accepts
/// WebSocket connections. Tailscale Serve sits in front of it and adds HTTPS,
/// which iPhones require before a web page may use the microphone.
@MainActor
final class MiniHTTPServer {
    struct Response {
        var status = "200 OK"
        var contentType: String
        var body: Data
    }

    /// Returns the file for a path ("/", "/manifest.webmanifest", …), or nil for 404.
    var route: ((String) -> Response?)?
    /// A new WebSocket client on /ws.
    var onSocket: ((WebSocketPeer) -> Void)?

    private var listener: NWListener?

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if done || error != nil || buffer.count > 65_536 { connection.cancel() } else {
                        self.readRequest(connection, buffer: buffer)
                    }
                    return
                }
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let rest = buffer[end.upperBound...]
                self.handle(head: head, leftover: Data(rest), connection: connection)
            }
        }
    }

    private func handle(head: String, leftover: Data, connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "/")

        if path == "/ws", headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
            let peer = WebSocketPeer(connection: connection, leftover: leftover)
            onSocket?(peer)
            peer.startReading()
            return
        }

        let response = route?(path) ?? Response(status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8))
        var reply = "HTTP/1.1 \(response.status)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\n"
        reply += "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(reply.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// One WebSocket connection (RFC 6455): text and binary messages, ping/pong
/// and close. Frames from the browser are masked; ours are not.
@MainActor
final class WebSocketPeer {
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private var buffer: Data
    private var fragments = Data()
    private var fragmentOpcode: UInt8 = 0
    private(set) var isOpen = true

    init(connection: NWConnection, leftover: Data) {
        self.connection = connection
        self.buffer = leftover
    }

    func startReading() {
        parse()
        receive()
    }

    func send(text: String) { sendFrame(opcode: 0x1, payload: Data(text.utf8)) }
    func send(binary: Data) { sendFrame(opcode: 0x2, payload: binary) }

    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        sendFrame(opcode: 0x1, payload: data)
    }

    /// Sends a close frame, then drops the connection once everything queued
    /// before it (like a last message) has gone out.
    func close() {
        guard isOpen else { return }
        sendFrame(opcode: 0x8, payload: Data()) { [connection] in connection.cancel() }
        finish(cancel: false)
    }

    private func finish(cancel: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        if cancel { connection.cancel() }
        onClose?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                if let data { self.buffer.append(data); self.parse() }
                if done || error != nil { self.finish() } else if self.isOpen { self.receive() }
            }
        }
    }

    private func parse() {
        while isOpen, buffer.count >= 2 {
            let b0 = buffer[buffer.startIndex], b1 = buffer[buffer.startIndex + 1]
            let fin = b0 & 0x80 != 0
            let opcode = b0 & 0x0F
            let masked = b1 & 0x80 != 0
            var length = Int(b1 & 0x7F)
            var offset = 2
            if length == 126 {
                guard buffer.count >= 4 else { return }
                length = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return }
                length = (2..<10).reduce(0) { $0 << 8 | Int(buffer[buffer.startIndex + $1]) }
                offset = 10
            }
            guard length < 16 << 20 else { finish(); return }
            let maskLength = masked ? 4 : 0
            guard buffer.count >= offset + maskLength + length else { return }
            let start = buffer.startIndex
            var payload = Data(buffer[(start + offset + maskLength)..<(start + offset + maskLength + length)])
            if masked {
                let mask = Array(buffer[(start + offset)..<(start + offset + 4)])
                payload.withUnsafeMutableBytes { raw in
                    for i in 0..<raw.count { raw[i] ^= mask[i % 4] }
                }
            }
            buffer = Data(buffer[(start + offset + maskLength + length)...])
            handleFrame(fin: fin, opcode: opcode, payload: payload)
        }
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x0:
            fragments.append(payload)
            if fin { deliver(opcode: fragmentOpcode, payload: fragments); fragments = Data() }
        case 0x1, 0x2:
            if fin { deliver(opcode: opcode, payload: payload) } else { fragmentOpcode = opcode; fragments = payload }
        case 0x8: close()
        case 0x9: sendFrame(opcode: 0xA, payload: payload)
        default: break
        }
    }

    private func deliver(opcode: UInt8, payload: Data) {
        if opcode == 0x1 { onText?(String(decoding: payload, as: UTF8.self)) } else { onBinary?(payload) }
    }

    private func sendFrame(opcode: UInt8, payload: Data, then done: (() -> Void)? = nil) {
        guard isOpen else { return }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in done?() })
    }
}
