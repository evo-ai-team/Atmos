import Foundation

/// A locally hosted itinerary demo. The helper returns an opaque ticket, never
/// the destination to open. Both endpoints are built from the same loopback URL.
enum ItineraryDemo {
    static func matches(_ transcript: String) -> Bool {
        guard ProcessInfo.processInfo.environment["ATMOS_ITINERARY_DEMO"] == "1" else { return false }
        let words = transcript.lowercased().split { !$0.isLetter && !$0.isNumber }
        let text = words.joined(separator: " ")
        let vocabulary = Set(words)
        let city = vocabulary.contains("richmond") || vocabulary.contains("sf")
            || text.contains("san francisco") || text.contains("s f ")
        let event = vocabulary.contains("hackathon") || text.contains("hack a thon")
            || text.contains("aws loft") || text.contains("aws builder loft")
        guard city && event else { return false }
        let plan = #"\b(?:plan|planning|organize|organise|schedule) (?:\w+ ){0,6}(?:itinerary|visit|trip|day|stay|weekend)\b"#
        let display = #"\b(?:show|open|create|build|make|give|draft|want|need) (?:(?:me|us|a|an|the|my|our|weekend|friday|richmond|san|francisco|sf|hackathon) ){0,7}itinerary\b"#
        return [plan, display].contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private struct Submission: Encodable { let transcript: String }
    private struct Reply: Decodable { let ticket: String }
    private enum HandoffError: Error { case invalidReply }

    private final class DeclineRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func handoff(_ transcript: String) async throws -> URL {
        let configured = ProcessInfo.processInfo.environment["ATMOS_DEMO_PORT"] ?? ""
        let candidate = UInt16(configured)
        let port = candidate.flatMap { $0 > 0 ? $0 : nil } ?? 4317
        var address = URLComponents()
        address.scheme = "http"
        address.host = "127.0.0.1"
        address.port = Int(port)
        guard let base = address.url else { throw HandoffError.invalidReply }
        let endpoint = base.appendingPathComponent("api").appendingPathComponent("handoff")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("native-demo", forHTTPHeaderField: "X-Atmos-Client")
        request.httpBody = try JSONEncoder().encode(Submission(transcript: transcript))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration, delegate: DeclineRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.url == endpoint, http.mimeType == "application/json" else { throw HandoffError.invalidReply }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1024 else { throw HandoffError.invalidReply }
            data.append(byte)
        }
        let ticket = try JSONDecoder().decode(Reply.self, from: data).ticket
        guard ticket.utf8.count == 64, ticket.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw HandoffError.invalidReply }
        return base.appendingPathComponent("handoff").appendingPathComponent(ticket)
    }
}
