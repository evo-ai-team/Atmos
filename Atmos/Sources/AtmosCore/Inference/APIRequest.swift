import Foundation

/// Shared HTTP setup only. Clients retain their own payloads, failure messages,
/// cancellation handling, and no-retry policies.
enum APIRequest {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias MeasuredTransport = @Sendable (URLRequest, PipelineTiming?) async throws -> MeasuredResponse

    struct MeasuredResponse: Sendable {
        let data: Data
        let response: URLResponse
        let diagnostics: HTTPRequestTiming?
    }

    static func ephemeralTransport(label: String) -> MeasuredTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        return measuredTransport(session: session, label: label)
    }

    // Keeping session construction separate permits URLProtocol-only tests of the
    // real instrumentation path, without contacting a service or loading a key.
    static func measuredTransport(session: URLSession, label: String) -> MeasuredTransport {
        return { request, timing in
            let diagnostics = timing.map { HTTPRequestTiming(label: label, request: request, timing: $0) }
            do {
                let (data, response) = try await session.data(for: request, delegate: diagnostics)
                diagnostics?.completed(data: data, response: response)
                return MeasuredResponse(data: data, response: response, diagnostics: diagnostics)
            } catch {
                diagnostics?.completed(data: nil, response: nil, error: error)
                throw error
            }
        }
    }

    static func measuredTransport(_ transport: @escaping Transport) -> MeasuredTransport {
        return { request, _ in
            let (data, response) = try await transport(request)
            return MeasuredResponse(data: data, response: response, diagnostics: nil)
        }
    }

    static func make(endpoint: URL, apiKey: String, body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }
}
