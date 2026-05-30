import Foundation

/// In-memory state-machine implementation for tests/offline development.
public actor MockInstanceManager: InstanceManager {
    private var status: InstanceStatus
    private let endpoint: InstanceEndpoint
    /// If true, `start()` transitions stopped -> starting -> running synchronously.
    /// Tests can inspect the sequence via `transitions`.
    public private(set) var transitions: [InstanceStatus] = []
    public private(set) var preparePhases: [String] = []
    /// When set, the next start() will fail with this error.
    private var failNextStart: Error?

    public init(
        initial: InstanceStatus = .stopped,
        endpoint: InstanceEndpoint = InstanceEndpoint(id: "mock-instance", ip: "10.0.0.2", sshPort: 22)
    ) {
        self.status = initial
        self.endpoint = endpoint
        self.transitions = [initial]
    }

    public func currentStatus() async -> InstanceStatus { status }

    public func refreshStatus() async throws -> InstanceStatus { status }

    public func injectFailure(_ error: Error) { failNextStart = error }

    private func set(_ new: InstanceStatus) {
        status = new
        transitions.append(new)
    }

    public func start() async throws -> InstanceEndpoint {
        if let err = failNextStart {
            failNextStart = nil
            set(.error((err as? LocalizedError)?.errorDescription ?? "\(err)"))
            throw err
        }
        set(.starting)
        set(.running(ip: endpoint.ip, port: endpoint.sshPort))
        return endpoint
    }

    public func stop() async throws {
        set(.stopping)
        set(.stopped)
    }

    public func prepareEnvironment(progress: @Sendable @escaping (String) -> Void) async throws {
        let phases = [
            "Provisioning GPU instance…",
            "Bootstrapping pipeline environment…",
            "Creating snapshot of the prepared environment…",
            "Environment prepared."
        ]
        set(.starting)
        for phase in phases {
            preparePhases.append(phase)
            progress(phase)
        }
        set(.running(ip: endpoint.ip, port: endpoint.sshPort))
    }
}
