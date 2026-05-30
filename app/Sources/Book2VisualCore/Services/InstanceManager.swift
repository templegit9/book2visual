import Foundation

/// High-level lifecycle status of the GPU instance, surfaced to the UI.
public enum InstanceStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(ip: String, port: Int)
    case stopping
    case error(String)

    /// Coarse traffic-light color for the menu-bar indicator (cost awareness).
    public enum Light: Sendable { case grey, yellow, green, red }

    public var light: Light {
        switch self {
        case .stopped: return .grey
        case .starting, .stopping: return .yellow
        case .running: return .green
        case .error: return .red
        }
    }

    public var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .error: return "Error"
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Snapshot describing where the instance lives, for the tunnel.
public struct InstanceEndpoint: Equatable, Sendable {
    public let id: String
    public let ip: String
    public let sshPort: Int

    public init(id: String, ip: String, sshPort: Int) {
        self.id = id
        self.ip = ip
        self.sshPort = sshPort
    }
}

/// Lifecycle abstraction so the implementation is swappable (Risk-4 mitigation).
public protocol InstanceManager: Actor {
    /// Current status, recomputed from the authoritative source where applicable.
    func currentStatus() async -> InstanceStatus

    /// Provision (if needed) and start the instance; resolves once RUNNING with an IP.
    func start() async throws -> InstanceEndpoint

    /// Stop the instance (cost control).
    func stop() async throws

    /// Re-read status from the authoritative source (Thunder /instances/list).
    func refreshStatus() async throws -> InstanceStatus

    /// One-time provisioning flow: provision -> bootstrap -> snapshot.
    /// Reports human-readable phase strings via `progress`.
    func prepareEnvironment(progress: @Sendable @escaping (String) -> Void) async throws
}
