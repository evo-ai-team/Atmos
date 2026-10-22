import Foundation
import XCTest
@testable import MouseCore

final class HTTPRequestTimingTests: XCTestCase {
    private let wallStart = Date(timeIntervalSinceReferenceDate: 1_000)

    func testMetricsSeparateUploadResponseWaitAndResumeWithoutDoubleCountingTLS() throws {
        var transaction = HTTPMetricsSnapshot.Transaction()
        transaction.dnsStart = date(0.1); transaction.dnsEnd = date(0.2)
        transaction.connectStart = date(0.2); transaction.connectEnd = date(0.5)
        transaction.tlsStart = date(0.3); transaction.tlsEnd = date(0.5)
        transaction.requestStart = date(0.5); transaction.requestEnd = date(0.8)
        transaction.responseStart = date(1.4); transaction.responseEnd = date(1.5)
        let snapshot = HTTPMetricsSnapshot(taskStart: date(0.01), taskEnd: date(1.6), transactions: [transaction])
        let phases = snapshot.phases(wallStart: wallStart, uptimeStart: 100, callbackAt: 101.7)
        let byName = Dictionary(uniqueKeysWithValues: phases.map { ($0.name, $0) })
        for (name, expected) in [
            ("URLSession task", 1.59), ("setup/queue before first network activity", 0.1),
            ("transaction 1 DNS", 0.1), ("transaction 1 connect (includes TLS)", 0.3),
            ("transaction 1 TLS (inside connect)", 0.2), ("transaction 1 upload", 0.3),
            ("transaction 1 wait for first response byte", 0.6), ("transaction 1 download", 0.1),
            ("last response byte to metrics callback", 0.2)
        ] {
            let phase = try XCTUnwrap(byName[name], name)
            XCTAssertEqual(phase.end - phase.start, expected, accuracy: 0.0001, name)
        }
        XCTAssertEqual(phases.count, 9)
        XCTAssertEqual(byName["transaction 1 upload"]?.start, 100.5)
    }

    func testReusedConnectionOmitsMissingDNSAndTLSAndKeepsTransactionsDistinct() throws {
        var first = HTTPMetricsSnapshot.Transaction()
        first.requestStart = date(0.2); first.requestEnd = date(0.3)
        first.responseStart = date(0.6); first.responseEnd = date(0.7)
        first.reusedConnection = true
        var second = first
        second.requestStart = date(0.8); second.requestEnd = date(0.9)
        second.responseStart = date(1.2); second.responseEnd = date(1.3)
        let snapshot = HTTPMetricsSnapshot(taskStart: date(0), taskEnd: date(1.4), redirectCount: 1, transactions: [first, second])
        let phases = snapshot.phases(wallStart: wallStart, uptimeStart: 100, callbackAt: 101.5)
        XCTAssertFalse(phases.contains { $0.name.contains("DNS") || $0.name.contains("TLS") })
        XCTAssertTrue(phases.contains { $0.name == "transaction 2 upload" })
        XCTAssertEqual(try XCTUnwrap(phases.first { $0.name == "setup/queue before first network activity" }).end, 100.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(phases.first { $0.name == "last response byte to metrics callback" }).start, 101.3, accuracy: 0.0001)
    }

    func testInvalidMissingAndOutOfBoundsDatesDoNotProduceNegativeOrNonfiniteDurations() {
        var transaction = HTTPMetricsSnapshot.Transaction()
        transaction.dnsStart = date(0.2); transaction.dnsEnd = date(0.1)
        transaction.connectStart = Date(timeIntervalSinceReferenceDate: .nan)
        transaction.connectEnd = date(0.4)
        transaction.requestStart = date(-1); transaction.requestEnd = date(0.1)
        transaction.responseStart = date(0.5); transaction.responseEnd = date(4)
        let snapshot = HTTPMetricsSnapshot(taskStart: date(-2), taskEnd: date(5), transactions: [transaction])
        let phases = snapshot.phases(wallStart: wallStart, uptimeStart: 100, callbackAt: 101)
        XCTAssertFalse(phases.contains { $0.name.contains("DNS") || $0.name.contains("connect") })
        XCTAssertTrue(phases.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start && $0.start >= 100 && $0.end <= 101 })
        XCTAssertEqual(phases.first { $0.name == "transaction 1 upload" }?.start, 100)
        XCTAssertEqual(phases.first { $0.name == "transaction 1 download" }?.end, 101)
    }

    func testOnlySafeWhitelistedProviderHeadersAppearInMetadata() throws {
        let response = try httpResponse(headers: [
            "x-request-id": "req_ABC-123.4", "openai-processing-ms": " 800.25 ",
            "Authorization": "Bearer do-not-record", "x-private-content": "private command"
        ])
        let metadata = HTTPRequestTiming.responseMetadata(response).joined(separator: "\n")
        XCTAssertTrue(metadata.contains("req_ABC-123.4"))
        XCTAssertTrue(metadata.contains("800.250 ms"))
        XCTAssertTrue(metadata.contains("not a separate trace interval"))
        XCTAssertFalse(metadata.contains("do-not-record"))
        XCTAssertFalse(metadata.contains("private command"))
        for invalid in ["-1", "nan", "inf", "not-a-duration", String(repeating: "1", count: 65)] {
            let response = try httpResponse(headers: ["openai-processing-ms": invalid])
            XCTAssertFalse(HTTPRequestTiming.responseMetadata(response).joined().contains("processing"), invalid)
        }
        for invalid in ["line\nbreak", "spaces not allowed", "é", String(repeating: "a", count: 129), ""] {
            XCTAssertNil(HTTPRequestTiming.safeToken(invalid, maximumLength: 128))
        }
        XCTAssertEqual(HTTPRequestTiming.safeToken("http/1.1", maximumLength: 32, allowSlash: true), "http/1.1")
    }

    func testMeasuredTransportCollectsSafeMetadataAndPreservesPayloadOffline() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimingStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = APIRequest.measuredTransport(session: session, label: "Test")
        let request = APIRequest.make(endpoint: URL(string: "https://offline.invalid/success")!,
                                      apiKey: "private-key", body: Data("private command".utf8))
        let trace = PipelineTiming(origin: .typed)
        let result = try await transport(request, trace)
        result.diagnostics?.recordClientResume()
        result.diagnostics?.recordClientResume() // Repeated reporting is harmless.
        trace.finish(.succeeded)
        XCTAssertEqual(result.data, Data("private response".utf8))
        XCTAssertEqual((result.response as? HTTPURLResponse)?.statusCode, 200)
        let report = trace.report
        XCTAssertTrue(report.contains("request JSON body: 15 bytes"))
        XCTAssertTrue(report.contains("response decoded body: 16 bytes"))
        XCTAssertTrue(report.contains("provider request ID: req_offline"))
        XCTAssertTrue(report.contains("800.000 ms (reported by server"))
        XCTAssertEqual(report.components(separatedBy: "data await return to client resume (includes diagnostics)").count - 1, 1)
        for privateValue in ["private-key", "private command", "private response", "offline.invalid"] {
            XCTAssertFalse(report.contains(privateValue))
        }
    }

    func testMeasuredTransportPreservesCancellationErrorOffline() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimingStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = APIRequest.measuredTransport(session: session, label: "Test")
        let trace = PipelineTiming(origin: .typed)
        do {
            _ = try await transport(URLRequest(url: URL(string: "https://offline.invalid/cancel")!), trace)
            XCTFail("Expected the transport cancellation to propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        trace.finish(.cancelled)
        XCTAssertTrue(trace.report.contains("cancelled"))
        XCTAssertFalse(trace.report.contains("private transport failure"))
    }

    private func date(_ offset: TimeInterval) -> Date { wallStart.addingTimeInterval(offset) }

    private func httpResponse(headers: [String: String]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://offline.invalid/")!, statusCode: 200,
                                     httpVersion: "HTTP/2", headerFields: headers))
    }
}

/// Intercepts every request in its private session. No fixture can fall through
/// to a real network connection, regardless of the URL used by a test.
private final class TimingStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/cancel" {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled,
                userInfo: [NSLocalizedDescriptionKey: "private transport failure"]))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/2",
            headerFields: ["x-request-id": "req_offline", "openai-processing-ms": "800",
                           "x-private-content": "private response"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("private response".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
