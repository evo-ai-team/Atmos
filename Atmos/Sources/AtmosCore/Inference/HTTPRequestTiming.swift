import Foundation

/// URLSession exposes phase dates in wall time. A request-local anchor maps them
/// onto the trace's uptime clock; small sampling/clock adjustments can affect the
/// estimate. Missing or reversed dates are omitted rather than invented as zero.
struct HTTPMetricsSnapshot: Sendable {
    struct Transaction: Sendable {
        var fetchStart: Date?
        var dnsStart: Date?
        var dnsEnd: Date?
        var connectStart: Date?
        var connectEnd: Date?
        var tlsStart: Date?
        var tlsEnd: Date?
        var requestStart: Date?
        var requestEnd: Date?
        var responseStart: Date?
        var responseEnd: Date?
        var networkProtocol: String?
        var reusedConnection = false
        var proxyConnection = false
        var sentHeaderBytes: Int64 = 0
        var sentBodyBytes: Int64 = 0
        var receivedHeaderBytes: Int64 = 0
        var receivedBodyBytes: Int64 = 0

        init() {}

        init(_ metrics: URLSessionTaskTransactionMetrics) {
            fetchStart = metrics.fetchStartDate
            dnsStart = metrics.domainLookupStartDate
            dnsEnd = metrics.domainLookupEndDate
            connectStart = metrics.connectStartDate
            connectEnd = metrics.connectEndDate
            tlsStart = metrics.secureConnectionStartDate
            tlsEnd = metrics.secureConnectionEndDate
            requestStart = metrics.requestStartDate
            requestEnd = metrics.requestEndDate
            responseStart = metrics.responseStartDate
            responseEnd = metrics.responseEndDate
            networkProtocol = metrics.networkProtocolName
            reusedConnection = metrics.isReusedConnection
            proxyConnection = metrics.isProxyConnection
            sentHeaderBytes = metrics.countOfRequestHeaderBytesSent
            sentBodyBytes = metrics.countOfRequestBodyBytesSent
            receivedHeaderBytes = metrics.countOfResponseHeaderBytesReceived
            receivedBodyBytes = metrics.countOfResponseBodyBytesReceived
        }
    }

    struct Phase: Sendable {
        let name: String
        let start: TimeInterval
        let end: TimeInterval
    }

    let taskStart: Date
    let taskEnd: Date
    let redirectCount: Int
    let transactions: [Transaction]

    init(taskStart: Date, taskEnd: Date, redirectCount: Int = 0, transactions: [Transaction]) {
        self.taskStart = taskStart
        self.taskEnd = taskEnd
        self.redirectCount = redirectCount
        self.transactions = transactions
    }

    init(_ metrics: URLSessionTaskMetrics) {
        self.init(taskStart: metrics.taskInterval.start, taskEnd: metrics.taskInterval.end,
                  redirectCount: metrics.redirectCount,
                  transactions: metrics.transactionMetrics.map(Transaction.init))
    }

    func phases(wallStart: Date, uptimeStart: TimeInterval, callbackAt: TimeInterval) -> [Phase] {
        var result: [Phase] = []
        func add(_ name: String, _ start: Date?, _ end: Date?) {
            guard let start, let end else { return }
            let from = uptimeStart + start.timeIntervalSince(wallStart)
            let to = uptimeStart + end.timeIntervalSince(wallStart)
            guard from.isFinite, to.isFinite, to >= from,
                  uptimeStart.isFinite, callbackAt.isFinite, callbackAt >= uptimeStart else { return }
            result.append(Phase(name: name,
                                start: min(callbackAt, max(uptimeStart, from)),
                                end: min(callbackAt, max(uptimeStart, to))))
        }
        add("URLSession task", taskStart, taskEnd)
        // A reused connection has no DNS/connect timestamps. Request start is
        // then the earliest exposed network activity; this gap may include queueing.
        let firstNetworkDate = transactions.flatMap {
            [$0.dnsStart, $0.connectStart, $0.requestStart].compactMap { $0 }
        }.filter { $0.timeIntervalSinceReferenceDate.isFinite }.min()
        add("setup/queue before first network activity", wallStart, firstNetworkDate)
        for (index, transaction) in transactions.enumerated() {
            let prefix = "transaction \(index + 1) "
            add(prefix + "DNS", transaction.dnsStart, transaction.dnsEnd)
            // URLSession's connect interval includes TLS. These rows overlap.
            add(prefix + "connect (includes TLS)", transaction.connectStart, transaction.connectEnd)
            add(prefix + "TLS (inside connect)", transaction.tlsStart, transaction.tlsEnd)
            add(prefix + "upload", transaction.requestStart, transaction.requestEnd)
            // Includes server work AND transit; never label this inference time.
            add(prefix + "wait for first response byte", transaction.requestEnd, transaction.responseStart)
            add(prefix + "download", transaction.responseStart, transaction.responseEnd)
        }
        let lastResponseDate = transactions.compactMap(\.responseEnd)
            .filter { $0.timeIntervalSinceReferenceDate.isFinite }.max()
        let callbackDate = wallStart.addingTimeInterval(callbackAt - uptimeStart)
        add("last response byte to metrics callback", lastResponseDate, callbackDate)
        return result
    }
}

/// One delegate per request keeps concurrent requests and reused session
/// connections distinct. It observes data(for:delegate:); Foundation continues to
/// own completion and cancellation. Diagnostics never wait for a metrics callback.
final class HTTPRequestTiming: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let label: String
    private let timing: PipelineTiming
    private let wallStart: Date
    private let uptimeStart: TimeInterval
    private let lock = NSLock()
    private var metrics: HTTPMetricsSnapshot?
    private var callbackAt: TimeInterval?
    private var returnedAt: TimeInterval?
    private var outcome: PipelineTiming.Outcome = .running
    private var metricsEmitted = false
    private var clientResumeRecorded = false
    private var wallClockShifted = false

    init(label: String, request: URLRequest, timing: PipelineTiming) {
        self.label = "\(label) HTTP [\(UUID().uuidString.prefix(8))]"
        self.timing = timing
        uptimeStart = ProcessInfo.processInfo.systemUptime
        wallStart = Date()
        super.init()
        annotate("request JSON body: \(request.httpBody?.count ?? 0) bytes")
    }

    func annotate(_ message: String) { timing.annotate("\(label) · \(message)") }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = HTTPMetricsSnapshot(metrics)
        lock.lock()
        self.metrics = snapshot
        callbackAt = now
        emitMetricsIfReady()
        lock.unlock()
    }

    func completed(data: Data?, response: URLResponse?, error: Error? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let wallElapsed = Date().timeIntervalSince(wallStart)
        let result: PipelineTiming.Outcome = error == nil ? .succeeded
            : (error is CancellationError || (error as? URLError)?.code == .cancelled ? .cancelled : .failed)
        lock.lock()
        guard returnedAt == nil else { lock.unlock(); return }
        returnedAt = now
        outcome = result
        // Large clock corrections make date→uptime placement misleading. The
        // enclosing monotonic HTTP timer remains reliable, so omit phase dates.
        wallClockShifted = !wallElapsed.isFinite || abs(wallElapsed - (now - uptimeStart)) > 0.25
        if let data { annotate("response decoded body: \(data.count) bytes") }
        if let http = response as? HTTPURLResponse {
            for message in Self.responseMetadata(http) { annotate(message) }
        }
        if metrics == nil { annotate("URLSession phase metrics unavailable at transport return") }
        emitMetricsIfReady()
        lock.unlock()
    }

    /// Called immediately after the caller's actor resumes from the transport.
    /// The interval starts when the data await returned, so it includes diagnostic
    /// bookkeeping as well as transport return and Swift actor scheduling.
    func recordClientResume() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard let returnedAt, !clientResumeRecorded else { lock.unlock(); return }
        clientResumeRecorded = true
        lock.unlock()
        timing.record("\(label) data await return to client resume (includes diagnostics)", from: returnedAt, to: now)
    }

    // Caller holds lock. Trace operations are small memory edits, never I/O.
    private func emitMetricsIfReady() {
        guard !metricsEmitted, let metrics, let callbackAt, let returnedAt else { return }
        metricsEmitted = true
        annotate("\(metrics.transactions.count) transaction(s), \(metrics.redirectCount) redirect(s); phase dates mapped approximately to uptime")
        if wallClockShifted {
            annotate("wall clock changed during request; URLSession date-based phases omitted")
        } else {
            for phase in metrics.phases(wallStart: wallStart, uptimeStart: uptimeStart, callbackAt: callbackAt) {
                timing.record("\(label) \(phase.name)", from: phase.start, to: phase.end, outcome: outcome)
            }
        }
        if callbackAt <= returnedAt {
            timing.record("\(label) metrics callback to data await return", from: callbackAt, to: returnedAt, outcome: outcome)
        }
        for (index, transaction) in metrics.transactions.enumerated() {
            let protocolName = Self.safeToken(transaction.networkProtocol, maximumLength: 32, allowSlash: true) ?? "unavailable"
            annotate("transaction \(index + 1): protocol=\(protocolName), reused=\(transaction.reusedConnection), proxy=\(transaction.proxyConnection)")
            let counts = [
                ("request headers", transaction.sentHeaderBytes), ("request body", transaction.sentBodyBytes),
                ("response headers", transaction.receivedHeaderBytes), ("response body", transaction.receivedBodyBytes)
            ].filter { $0.1 >= 0 }.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
            annotate("transaction \(index + 1) transferred bytes: \(counts)")
        }
    }

    static func responseMetadata(_ response: HTTPURLResponse) -> [String] {
        var messages = ["HTTP status: \(response.statusCode)"]
        if let requestID = safeToken(response.value(forHTTPHeaderField: "x-request-id"), maximumLength: 128) {
            messages.append("provider request ID: \(requestID)")
        }
        if let raw = response.value(forHTTPHeaderField: "openai-processing-ms"), raw.count <= 64,
           let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value >= 0 {
            let formatted = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, value))
            messages.append("provider openai-processing-ms: \(formatted) ms (reported by server; not a separate trace interval)")
        }
        return messages
    }

    /// Accept only bounded identifier/protocol characters, never arbitrary header
    /// text. Rejecting an invalid value avoids leaking bodies or multiline content.
    static func safeToken(_ value: String?, maximumLength: Int, allowSlash: Bool = false) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximumLength else { return nil }
        let punctuation = allowSlash ? "-._/" : "-._"
        guard value.unicodeScalars.allSatisfy({ scalar in
            (48...57).contains(scalar.value) || (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value) || punctuation.unicodeScalars.contains(scalar)
        }) else { return nil }
        return value
    }
}
