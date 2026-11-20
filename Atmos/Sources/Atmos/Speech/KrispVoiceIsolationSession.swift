import Foundation

/// One outbound PCM writer and one independent reader share a single stream.
/// Closing the session interrupts token creation, the handshake, and pending I/O.
final class KrispVoiceIsolationSession: @unchecked Sendable {
    static let model = "VIVA-pro"
    static let sampleRate = 32_000
    static let frameSamples = sampleRate * 30 / 1_000
    static let frameBytes = frameSamples * MemoryLayout<Int16>.size

    private enum Operation: String, Hashable {
        case connect = "connecting"
        case send = "sending audio"
        case receive = "receiving isolated audio"
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }

    private struct TokenReply: Decodable {
        struct Payload: Decodable { let session_key: String }
        let code: Int
        let data: Payload?
        let error_code: String?
    }

    private struct ServerEvent: Decodable {
        struct Detail: Decodable { let code: String }
        let type: String
        let error: Detail?
    }

    // This native client uses a user-supplied key to mint a scoped token.
    // Decline redirects so credentials are only presented to the intended host.
    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let apiKey: String
    private let network: URLSession
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var opening: Task<Void, Error>?
    private var watchdog: DispatchSourceTimer?
    private var deadlines: [Operation: ContinuousClock.Instant] = [:]
    private var terminalError: Error?
    private var ready = false

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "Atmos/1.0 (macOS)"]
        network = URLSession(configuration: config, delegate: RedirectDelegate(), delegateQueue: nil)
    }

    deinit {
        watchdog?.cancel()
        network.invalidateAndCancel()
    }

    func connect() async throws {
        try Task.checkCancellation()
        let task: Task<Void, Error> = try lock.withLock {
            if let terminalError { throw terminalError }
            guard !apiKey.isEmpty, !apiKey.contains(where: \.isNewline) else {
                throw Failure("Enter a valid Krisp API key in Settings.")
            }
            guard opening == nil, !ready else { throw Failure("Krisp is already connecting or connected.") }
            deadlines[.connect] = .now.advanced(by: .seconds(15))
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.checkDeadlines() }
            timer.resume()
            watchdog = timer
            let task = Task { try await openStream() }
            opening = task
            return task
        }
        try await withTaskCancellationHandler {
            do {
                try await task.value
                try Task.checkCancellation()
                try lock.withLock {
                    if let terminalError { throw terminalError }
                    deadlines.removeValue(forKey: .connect)
                    opening = nil
                    ready = true
                }
            } catch {
                throw terminate(error)
            }
        } onCancel: { self.close() }
    }

    private func openStream() async throws {
        let tokenURL = URL(string: "https://api.developers.krisp.ai/v2/sdk/tokens/session")!
        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("api-key \(apiKey)", forHTTPHeaderField: "Authorization")
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = Data(#"{"usage_type":"viva","expiration_ttl":300}"#.utf8)
        let (data, response) = try await network.data(for: tokenRequest)
        let reply = try? JSONDecoder().decode(TokenReply.self, from: data)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw Failure("Krisp returned an invalid authorization response.")
        }
        guard (200..<300).contains(status), reply?.code == 0,
              let token = reply?.data?.session_key, !token.isEmpty, !token.contains(where: \.isNewline) else {
            throw Failure("Krisp authorization failed (HTTP \(status)\(Self.codeSuffix(reply?.error_code))).")
        }
        try Task.checkCancellation()
        let streamURL = URL(string: "wss://streaming.krisp.ai/voice-isolation")!
        var request = URLRequest(url: streamURL)
        request.setValue("api-key \(token)", forHTTPHeaderField: "Authorization")
        let stream = try lock.withLock {
            if let terminalError { throw terminalError }
            let task = network.webSocketTask(with: request)
            task.maximumMessageSize = 65_536
            socket = task
            task.resume()
            return task
        }
        let hello: [String: Any] = ["model": Self.model, "sample_rate": Self.sampleRate, "suppression_level": 100]
        let helloData = try JSONSerialization.data(withJSONObject: hello)
        try await stream.send(.string(String(decoding: helloData, as: UTF8.self)))
        guard case .string(let text) = try await stream.receive() else {
            throw Failure("Krisp sent audio before accepting the voice isolation model.")
        }
        guard try Self.parseEvent(text).type == "ready" else {
            throw Failure("Krisp did not confirm the voice isolation session.")
        }
    }

    func send(_ frame: Data) async throws {
        guard frame.count == Self.frameBytes else { throw Failure("Krisp requires one 30 ms PCM frame per message.") }
        try await perform(.send) { try await $0.send(.data(frame)) }
    }

    func receive() async throws -> Data {
        try await perform(.receive) { stream in
            switch try await stream.receive() {
            case .data(let data) where !data.isEmpty:
                return data
            case .string(let text):
                _ = try Self.parseEvent(text)
                throw Failure("Krisp returned an unexpected control message during audio processing.")
            default:
                throw Failure("Krisp returned an empty or invalid audio message.")
            }
        }
    }

    private static func parseEvent(_ text: String) throws -> ServerEvent {
        guard let event = try? JSONDecoder().decode(ServerEvent.self, from: Data(text.utf8)) else {
            throw Failure("Krisp returned an unreadable control message.")
        }
        if event.type == "error" {
            throw Failure("Krisp voice isolation failed\(codeSuffix(event.error?.code)).")
        }
        return event
    }

    // Display diagnostic identifiers without including server messages, headers or audio.
    private static func codeSuffix(_ code: String?) -> String {
        guard let code, !code.isEmpty, code.utf8.count <= 64,
              code.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else {
            return ""
        }
        return " \(code)"
    }

    private func perform<T>(_ operation: Operation,
                            _ body: (URLSessionWebSocketTask) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let stream: URLSessionWebSocketTask = try lock.withLock {
            if let terminalError { throw terminalError }
            guard ready, let socket else { throw Failure("Krisp voice isolation is not connected.") }
            guard deadlines[operation] == nil else { throw Failure("Concurrent Krisp operations attempted \(operation.rawValue).") }
            deadlines[operation] = .now.advanced(by: .seconds(10))
            return socket
        }
        defer { _ = lock.withLock { deadlines.removeValue(forKey: operation) } }
        return try await withTaskCancellationHandler {
            do {
                let result = try await body(stream)
                try Task.checkCancellation()
                try lock.withLock { if let terminalError { throw terminalError } }
                return result
            } catch {
                throw terminate(error)
            }
        } onCancel: { self.close() }
    }

    private func checkDeadlines() {
        let overdue = lock.withLock { deadlines.first { $0.value <= .now }?.key }
        if let overdue {
            _ = terminate(Failure("Krisp timed out while \(overdue.rawValue)."))
        }
    }

    func close() { _ = terminate(CancellationError()) }

    /// Preserve the first failure so the cancellation it triggers on the other
    /// half of the stream cannot hide the actual reason the session ended.
    private func terminate(_ reason: Error) -> Error {
        let (error, task, stream, timer): (Error, Task<Void, Error>?, URLSessionWebSocketTask?, DispatchSourceTimer?) = lock.withLock {
            if let terminalError {
                return (terminalError, nil, nil, nil)
            }
            terminalError = reason
            let resources = (reason, opening, socket, watchdog)
            opening = nil
            socket = nil
            watchdog = nil
            deadlines.removeAll()
            return resources
        }
        timer?.cancel()
        task?.cancel()
        stream?.cancel(with: .goingAway, reason: nil)
        return error
    }
}
