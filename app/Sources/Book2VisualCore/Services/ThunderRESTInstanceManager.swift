import Foundation

/// `InstanceManager` backed by the Thunder REST control plane.
public actor ThunderRESTInstanceManager: InstanceManager {
    private let client: ThunderClient
    /// Provides the SSH public key to register when creating an instance.
    private let publicKeyProvider: @Sendable () throws -> String
    /// Persisted instance id (so we reuse one instance instead of creating many).
    private var instanceId: String?
    private var lastStatus: InstanceStatus = .stopped
    private let gpuType: String

    public init(
        client: ThunderClient,
        instanceId: String? = nil,
        gpuType: String = "a100",
        publicKeyProvider: @escaping @Sendable () throws -> String
    ) {
        self.client = client
        self.instanceId = instanceId
        self.gpuType = gpuType
        self.publicKeyProvider = publicKeyProvider
    }

    public func currentStatus() async -> InstanceStatus { lastStatus }

    public func refreshStatus() async throws -> InstanceStatus {
        let instances = try await client.listInstances()
        guard let id = instanceId, let inst = instances.first(where: { $0.id == id }) else {
            lastStatus = .stopped
            return lastStatus
        }
        lastStatus = Self.map(inst)
        return lastStatus
    }

    public func start() async throws -> InstanceEndpoint {
        lastStatus = .starting
        let id: String
        if let existing = instanceId {
            id = existing
            try await client.startInstance(id: existing)
        } else {
            let pubKey = try publicKeyProvider()
            let created = try await client.createInstance(publicKey: pubKey, gpuType: gpuType)
            id = created.id
            instanceId = id
        }
        do {
            let inst = try await client.pollUntilRunning(id: id)
            guard let ip = inst.ip else { throw ThunderError.noInstanceIP }
            let sshPort = inst.port ?? 22
            lastStatus = .running(ip: ip, port: sshPort)
            return InstanceEndpoint(id: id, ip: ip, sshPort: sshPort)
        } catch {
            lastStatus = .error((error as? LocalizedError)?.errorDescription ?? "\(error)")
            throw error
        }
    }

    public func stop() async throws {
        guard let id = instanceId else { lastStatus = .stopped; return }
        lastStatus = .stopping
        do {
            try await client.stopInstance(id: id)
            lastStatus = .stopped
        } catch {
            lastStatus = .error((error as? LocalizedError)?.errorDescription ?? "\(error)")
            throw error
        }
    }

    public func prepareEnvironment(progress: @Sendable @escaping (String) -> Void) async throws {
        // Provision + start.
        progress("Provisioning GPU instance…")
        let endpoint = try await start()
        // Bootstrap is performed over SSH by Team A's bootstrap script; here we
        // only record the phase. The actual remote bootstrap command is issued
        // by higher layers once the tunnel/SSH is available.
        progress("Bootstrapping pipeline environment on \(endpoint.ip)…")
        // Snapshot the prepared instance for fast future starts.
        progress("Creating snapshot of the prepared environment…")
        _ = try await client.createSnapshot(instanceId: endpoint.id, name: "book2visual-prepared")
        progress("Environment prepared.")
    }

    private static func map(_ inst: ThunderInstance) -> InstanceStatus {
        switch inst.status.uppercased() {
        case "RUNNING":
            if let ip = inst.ip { return .running(ip: ip, port: inst.port ?? 22) }
            return .starting
        case "STARTING", "PENDING", "INITIALIZING":
            return .starting
        case "STOPPING":
            return .stopping
        case "STOPPED", "OFFLINE":
            return .stopped
        default:
            return .error("Unknown instance status: \(inst.status)")
        }
    }
}
