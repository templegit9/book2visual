import Foundation

/// Errors surfaced by the Thunder control plane.
public enum ThunderError: LocalizedError, Equatable {
    case missingToken
    case http(status: Int, body: String)
    case decoding(String)
    case timedOut
    case noInstanceIP
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No ThunderCompute API token is configured. Add one in Settings."
        case .http(let status, let body):
            return "Thunder API returned HTTP \(status): \(body)"
        case .decoding(let detail):
            return "Could not decode Thunder API response: \(detail)"
        case .timedOut:
            return "Timed out waiting for the instance to reach RUNNING."
        case .noInstanceIP:
            return "Instance is RUNNING but no IP address was returned."
        case .transport(let detail):
            return "Network error talking to Thunder API: \(detail)"
        }
    }
}

/// Errors surfaced by the pipeline data plane (over the tunnel) and tunnel itself.
public enum JobError: LocalizedError, Equatable {
    case notReachable(String)
    case http(status: Int, body: String)
    case decoding(String)
    case jobAlreadyRunning
    case outputNotReady
    case noOutput
    case pipeline(code: String, message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notReachable(let detail):
            return "Pipeline service is not reachable over the tunnel: \(detail)"
        case .http(let status, let body):
            return "Pipeline service returned HTTP \(status): \(body)"
        case .decoding(let detail):
            return "Could not decode pipeline response: \(detail)"
        case .jobAlreadyRunning:
            return "A job is already running on the instance."
        case .outputNotReady:
            return "The job output is not ready yet."
        case .noOutput:
            return "No output was produced for this job."
        case .pipeline(let code, let message):
            return "Pipeline error [\(code)]: \(message)"
        case .cancelled:
            return "The job was cancelled."
        }
    }
}

public enum SSHTunnelError: LocalizedError, Equatable {
    case missingKey
    case launchFailed(String)
    case exited(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No SSH private key is available to open the tunnel."
        case .launchFailed(let detail):
            return "Failed to launch ssh: \(detail)"
        case .exited(let code):
            return "ssh tunnel process exited with code \(code)."
        }
    }
}

public enum KeychainError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case keygenFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain operation failed (OSStatus \(status))."
        case .encodingFailed:
            return "Failed to encode value for the Keychain."
        case .keygenFailed(let detail):
            return "Failed to generate an SSH keypair: \(detail)"
        }
    }
}
