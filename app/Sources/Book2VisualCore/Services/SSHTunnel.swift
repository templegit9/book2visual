import Foundation

/// Configuration for a local-forward SSH tunnel to the instance.
public struct SSHTunnelConfig: Equatable, Sendable {
    public var localPort: Int
    public var remotePort: Int
    public var host: String
    public var sshPort: Int
    public var keyPath: String
    public var user: String

    public init(
        localPort: Int = 8000,
        remotePort: Int = 8000,
        host: String,
        sshPort: Int = 22,
        keyPath: String,
        user: String = "ubuntu"
    ) {
        self.localPort = localPort
        self.remotePort = remotePort
        self.host = host
        self.sshPort = sshPort
        self.keyPath = keyPath
        self.user = user
    }

    /// The ssh argument vector. SSH user is **ubuntu**.
    public var arguments: [String] {
        [
            "-N",
            "-L", "\(localPort):127.0.0.1:\(remotePort)",
            "-i", keyPath,
            "-p", "\(sshPort)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "\(user)@\(host)"
        ]
    }
}

public enum SSHTunnelState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected(String)
}

/// Manages a background `/usr/bin/ssh` Process running an `-L` local forward.
/// Monitors process exit and exposes a `reconnect()`.
public actor SSHTunnel {
    public private(set) var state: SSHTunnelState = .idle

    private var process: Process?
    private let sshPath: String
    private var config: SSHTunnelConfig?
    private var stateObserver: (@Sendable (SSHTunnelState) -> Void)?

    public init(sshPath: String = "/usr/bin/ssh") {
        self.sshPath = sshPath
    }

    /// Register a callback invoked on every state change (for the UI).
    public func observe(_ observer: @escaping @Sendable (SSHTunnelState) -> Void) {
        self.stateObserver = observer
        observer(state)
    }

    private func transition(to newState: SSHTunnelState) {
        state = newState
        stateObserver?(newState)
    }

    /// Launch the tunnel. Throws if the process can't be started or the key is missing.
    public func start(config: SSHTunnelConfig) throws {
        guard FileManager.default.fileExists(atPath: config.keyPath) else {
            throw SSHTunnelError.missingKey
        }
        self.config = config
        try launch(config)
    }

    private func launch(_ config: SSHTunnelConfig) throws {
        transition(to: .connecting)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: sshPath)
        proc.arguments = config.arguments
        // Discard ssh chatter; ServerAlive keeps the tunnel honest.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = Pipe()

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            Task { await self.handleExit(code: p.terminationStatus) }
        }

        do {
            try proc.run()
        } catch {
            transition(to: .disconnected("launch failed"))
            throw SSHTunnelError.launchFailed(String(describing: error))
        }
        self.process = proc
        // `ssh -N` stays resident; we optimistically mark connected. Health checks
        // via JobClient.health() confirm end-to-end reachability.
        transition(to: .connected)
    }

    private func handleExit(code: Int32) {
        process = nil
        if code == 0 {
            transition(to: .idle)
        } else {
            transition(to: .disconnected("ssh exited with code \(code)"))
        }
    }

    /// Tear down and relaunch with the last-used config.
    public func reconnect() throws {
        guard let config else { return }
        stop()
        try launch(config)
    }

    /// Terminate the ssh process if running. Safe to call on stop/quit.
    public func stop() {
        if let proc = process, proc.isRunning {
            proc.terminationHandler = nil
            proc.terminate()
        }
        process = nil
        transition(to: .idle)
    }

    /// Whether the underlying process is currently alive.
    public var isRunning: Bool {
        process?.isRunning ?? false
    }
}
