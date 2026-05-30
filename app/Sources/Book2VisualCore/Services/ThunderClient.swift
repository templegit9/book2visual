import Foundation

// MARK: - Wire models (Thunder control plane)

/// One instance as returned by GET /instances/list. `/instances/list` is the
/// ONLY status source per the architecture spec.
public struct ThunderInstance: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let ip: String?
    public let port: Int?
    public let gpuType: String?

    public init(id: String, status: String, ip: String?, port: Int?, gpuType: String?) {
        self.id = id
        self.status = status
        self.ip = ip
        self.port = port
        self.gpuType = gpuType
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case ip
        case port
        case gpuType = "gpu_type"
    }

    public var isRunning: Bool { status.uppercased() == "RUNNING" }
}

/// Response of POST /instances/create.
public struct CreateInstanceResponse: Codable, Equatable, Sendable {
    public let id: String

    public init(id: String) { self.id = id }
}

/// Response of POST /snapshots/create.
public struct CreateSnapshotResponse: Codable, Equatable, Sendable {
    public let id: String

    public init(id: String) { self.id = id }
}

// MARK: - Abstraction for testability

/// Minimal HTTP transport so ThunderClient can be tested without real URLSession.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

// MARK: - ThunderClient

/// URLSession REST client for the ThunderCompute control plane.
/// Base: https://api.thundercompute.com:8443, Bearer auth.
public actor ThunderClient {
    public static let defaultBaseURL = URL(string: "https://api.thundercompute.com:8443")!

    private let baseURL: URL
    private let transport: HTTPTransport
    private let tokenProvider: @Sendable () throws -> String

    /// - Parameters:
    ///   - tokenProvider: returns the Bearer token (typically reads Keychain).
    public init(
        baseURL: URL = ThunderClient.defaultBaseURL,
        transport: HTTPTransport = URLSession.shared,
        tokenProvider: @escaping @Sendable () throws -> String
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokenProvider = tokenProvider
    }

    // MARK: Lifecycle

    /// POST /instances/create — sends our public key, GPU a100, production mode.
    public func createInstance(publicKey: String, gpuType: String = "a100") async throws -> CreateInstanceResponse {
        let body: [String: Any] = [
            "public_key": publicKey,
            "gpu_type": gpuType,
            "mode": "production",
            "num_gpus": 1
        ]
        return try await postJSON(path: "/instances/create", body: body)
    }

    /// GET /instances/list — the ONLY status source.
    public func listInstances() async throws -> [ThunderInstance] {
        let req = try makeRequest(path: "/instances/list", method: "GET")
        let data = try await send(req)
        do {
            return try ContractCoding.decoder().decode([ThunderInstance].self, from: data)
        } catch {
            // Some control planes wrap the list in an envelope; tolerate {"instances":[...]}.
            struct Envelope: Decodable { let instances: [ThunderInstance] }
            if let env = try? ContractCoding.decoder().decode(Envelope.self, from: data) {
                return env.instances
            }
            throw ThunderError.decoding(String(describing: error))
        }
    }

    /// POST /instances/{id}/up
    public func startInstance(id: String) async throws {
        _ = try await postRaw(path: "/instances/\(id)/up", body: [:])
    }

    /// POST /instances/{id}/down
    public func stopInstance(id: String) async throws {
        _ = try await postRaw(path: "/instances/\(id)/down", body: [:])
    }

    /// POST /instances/{id}/delete
    public func deleteInstance(id: String) async throws {
        _ = try await postRaw(path: "/instances/\(id)/delete", body: [:])
    }

    /// POST /snapshots/create
    public func createSnapshot(instanceId: String, name: String) async throws -> CreateSnapshotResponse {
        let body: [String: Any] = ["instance_id": instanceId, "name": name]
        return try await postJSON(path: "/snapshots/create", body: body)
    }

    // MARK: Polling

    /// Poll /instances/list every `interval` until the instance is RUNNING with an IP,
    /// or `timeout` elapses. Returns the running instance.
    public func pollUntilRunning(
        id: String,
        interval: TimeInterval = 10,
        timeout: TimeInterval = 300,
        sleeper: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws -> ThunderInstance {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            let instances = try await listInstances()
            if let inst = instances.first(where: { $0.id == id }) {
                if inst.isRunning {
                    guard inst.ip != nil else { throw ThunderError.noInstanceIP }
                    return inst
                }
            }
            if Date() >= deadline { throw ThunderError.timedOut }
            try await sleeper(interval)
        }
    }

    // MARK: - Plumbing

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        let token = try tokenProvider()
        guard !token.isEmpty else { throw ThunderError.missingToken }
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw ThunderError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ThunderError.transport("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ThunderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func postRaw(path: String, body: [String: Any]) async throws -> Data {
        var req = try makeRequest(path: path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private func postJSON<T: Decodable>(path: String, body: [String: Any]) async throws -> T {
        let data = try await postRaw(path: path, body: body)
        do {
            return try ContractCoding.decoder().decode(T.self, from: data)
        } catch {
            throw ThunderError.decoding(String(describing: error))
        }
    }
}
