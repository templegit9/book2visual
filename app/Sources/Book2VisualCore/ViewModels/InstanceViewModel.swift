import Foundation
import Observation

/// Drives instance start/stop/prepare-environment and status polling.
@MainActor
@Observable
public final class InstanceViewModel {
    public private(set) var status: InstanceStatus = .stopped
    public private(set) var statusTimestamp: Date = Date()
    public private(set) var isBusy: Bool = false
    public private(set) var preparePhase: String?
    public var lastError: String?

    private let manager: any InstanceManager
    private let appState: AppState?
    /// Opened once the instance is Running so localhost:<localTunnelPort> reaches
    /// the FastAPI service on the instance. nil in the mock environment.
    private let tunnel: SSHTunnel?

    public init(
        manager: any InstanceManager,
        appState: AppState? = nil,
        tunnel: SSHTunnel? = nil
    ) {
        self.manager = manager
        self.appState = appState
        self.tunnel = tunnel
    }

    private func apply(_ new: InstanceStatus) {
        status = new
        statusTimestamp = Date()
        appState?.updateStatus(new)
    }

    public func start() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        apply(.starting)
        do {
            let endpoint = try await manager.start()
            try await openTunnel(to: endpoint)
            apply(.running(ip: endpoint.ip, port: endpoint.sshPort))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = message
            apply(.error(message))
        }
        isBusy = false
    }

    /// Open the SSH local-forward to the instance, if a tunnel + key are configured.
    private func openTunnel(to endpoint: InstanceEndpoint) async throws {
        guard let tunnel else { return }  // mock env: no tunnel
        guard let keyPath = appState?.settings.sshKeyPath, !keyPath.isEmpty else {
            throw SSHTunnelError.missingKey
        }
        let s = appState?.settings
        let config = SSHTunnelConfig(
            localPort: s?.localTunnelPort ?? 8000,
            remotePort: s?.fastAPIPort ?? 8000,
            host: endpoint.ip,
            sshPort: endpoint.sshPort,
            keyPath: keyPath
        )
        try await tunnel.start(config: config)
    }

    public func stop() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        apply(.stopping)
        await tunnel?.stop()
        do {
            try await manager.stop()
            apply(.stopped)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = message
            apply(.error(message))
        }
        isBusy = false
    }

    public func prepareEnvironment() async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        do {
            try await manager.prepareEnvironment { [weak self] phase in
                Task { @MainActor in self?.preparePhase = phase }
            }
            let s = await manager.currentStatus()
            apply(s)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = message
            apply(.error(message))
        }
        preparePhase = nil
        isBusy = false
    }

    public func refresh() async {
        do {
            let s = try await manager.refreshStatus()
            apply(s)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
