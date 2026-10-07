import Foundation

/// A thin WebSocket wrapper around the OpenAI Realtime API. Events go out
/// and come back as plain JSON dictionaries; `VoiceSession` interprets them.
final class RealtimeClient: NSObject, URLSessionWebSocketDelegate {
    var onEvent: (([String: Any]) -> Void)?
    var onClose: ((String?) -> Void)?

    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var closed = false

    func connect(apiKey: String, model: String) {
        var comps = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        comps.queryItems = [URLQueryItem(name: "model", value: model)]
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        closed = false
        task = session.webSocketTask(with: request)
        task?.maximumMessageSize = 64 * 1024 * 1024
        task?.resume()
        receive()
    }

    func send(_ event: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error { self?.finish(error.localizedDescription) }
        }
    }

    func disconnect() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                var data: Data?
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async { self.onEvent?(obj) }
                }
                self.receive()
            case .failure(let error):
                self.finish(error.localizedDescription)
            }
        }
    }

    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        DispatchQueue.main.async { self.onClose?(reason) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Connection closed")
    }
}
