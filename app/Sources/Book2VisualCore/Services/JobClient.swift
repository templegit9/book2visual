import Foundation

/// Health response from GET /health.
public struct HealthStatus: Codable, Equatable, Sendable {
    public let status: String
    public let modelsLoaded: Bool
    public let stub: Bool?

    public init(status: String, modelsLoaded: Bool, stub: Bool? = nil) {
        self.status = status
        self.modelsLoaded = modelsLoaded
        self.stub = stub
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case modelsLoaded = "models_loaded"
        case stub
    }

    public var isOK: Bool { status == "ok" }
}

/// The data-plane client contract (over the SSH tunnel).
public protocol JobClient: Sendable {
    /// GET /health — used for tunnel validation + heartbeat.
    func health() async throws -> HealthStatus
    /// POST /jobs — returns job_id. Throws `.jobAlreadyRunning` on 409.
    func submit(_ request: JobRequest) async throws -> String
    /// GET /jobs/{id}/stream — parsed SSE ProgressEvents until a terminal event.
    func streamEvents(jobId: String) -> AsyncThrowingStream<ProgressEvent, Error>
    /// POST /jobs/{id}/cancel
    func cancel(jobId: String) async throws
    /// GET /jobs/{id}/output — saves+unzips to App Support; returns the dir.
    func downloadOutput(jobId: String) async throws -> URL
}

/// REST/SSE client talking to the pipeline over `http://127.0.0.1:<localPort>`.
public struct HTTPJobClient: JobClient {
    private let baseURL: URL
    private let session: URLSession
    private let outputStore: OutputStore

    public init(localPort: Int = 8000, outputStore: OutputStore, session: URLSession = .shared) {
        self.baseURL = URL(string: "http://127.0.0.1:\(localPort)")!
        self.session = session
        self.outputStore = outputStore
    }

    public func health() async throws -> HealthStatus {
        let req = makeRequest(path: "/health", method: "GET")
        let (data, resp) = try await transport(req)
        try ensureOK(resp, data: data)
        do {
            return try ContractCoding.decoder().decode(HealthStatus.self, from: data)
        } catch {
            throw JobError.decoding(String(describing: error))
        }
    }

    public func submit(_ request: JobRequest) async throws -> String {
        var req = makeRequest(path: "/jobs", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try ContractCoding.encoder().encode(request)
        let (data, resp) = try await transport(req)
        guard let http = resp as? HTTPURLResponse else {
            throw JobError.notReachable("Non-HTTP response")
        }
        if http.statusCode == 409 { throw JobError.jobAlreadyRunning }
        try ensureOK(resp, data: data)
        struct Accepted: Decodable { let job_id: String }
        do {
            return try ContractCoding.decoder().decode(Accepted.self, from: data).job_id
        } catch {
            throw JobError.decoding(String(describing: error))
        }
    }

    public func streamEvents(jobId: String) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let req = makeRequest(path: "/jobs/\(jobId)/stream", method: "GET")
                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                        throw JobError.http(status: status, body: "stream")
                    }
                    var dataBuffer = ""
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            // Dispatch on blank-line event boundary.
                            if let event = Self.parseSSEData(dataBuffer) {
                                continuation.yield(event)
                                if event.type.isTerminal {
                                    continuation.finish()
                                    return
                                }
                            }
                            dataBuffer = ""
                        } else if line.hasPrefix("data:") {
                            let payload = String(line.dropFirst("data:".count))
                                .trimmingCharacters(in: .whitespaces)
                            dataBuffer += payload
                        }
                        // ignore comment/keepalive lines beginning with ':'
                    }
                    // Stream ended without trailing blank line; flush remaining.
                    if let event = Self.parseSSEData(dataBuffer) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func parseSSEData(_ raw: String) -> ProgressEvent? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        do {
            // Per contract every `data:` payload is a JSON ProgressEvent; a decode
            // failure is a contract violation worth surfacing, not silently dropping
            // (a swallowed terminal event would stall the stream to EOF).
            return try ContractCoding.decoder().decode(ProgressEvent.self, from: data)
        } catch {
            FileHandle.standardError.write(
                Data("[Book2Visual] SSE ProgressEvent decode failed: \(error)\n".utf8))
            return nil
        }
    }

    public func cancel(jobId: String) async throws {
        let req = makeRequest(path: "/jobs/\(jobId)/cancel", method: "POST")
        let (data, resp) = try await transport(req)
        try ensureOK(resp, data: data)
    }

    public func downloadOutput(jobId: String) async throws -> URL {
        let req = makeRequest(path: "/jobs/\(jobId)/output", method: "GET")
        let (data, resp) = try await transport(req)
        guard let http = resp as? HTTPURLResponse else {
            throw JobError.notReachable("Non-HTTP response")
        }
        if http.statusCode == 409 { throw JobError.outputNotReady }
        try ensureOK(resp, data: data)
        return try outputStore.saveAndUnzip(zipData: data, jobId: jobId)
    }

    // MARK: plumbing

    private func makeRequest(path: String, method: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func transport(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch {
            throw JobError.notReachable(String(describing: error))
        }
    }

    private func ensureOK(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw JobError.notReachable("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JobError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
