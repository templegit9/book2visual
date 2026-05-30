import Foundation

/// Manages the app's SSH keypair. Generates one in-app if none exists; the
/// private key is stored in the Keychain and (only when a tunnel needs it) is
/// materialized to a user-chosen path with 0600 permissions. The private key is
/// never written anywhere else.
public struct SSHKeyManager: Sendable {
    private let store: SecretStore

    public init(store: SecretStore) {
        self.store = store
    }

    /// Returns the stored public key, or nil if no keypair exists yet.
    public func publicKey() throws -> String? {
        try store.get(SSHKeyManager.publicKeyAccount)
    }

    public static let publicKeyAccount = "ssh.public.key"

    /// Ensure a keypair exists; returns the public key string (OpenSSH format).
    /// Uses `ssh-keygen` to produce an ed25519 keypair, storing both parts in the
    /// Keychain and shredding the temp files.
    @discardableResult
    public func ensureKeyPair(
        keygenPath: String = "/usr/bin/ssh-keygen"
    ) throws -> String {
        if let existing = try publicKey(), !existing.isEmpty {
            return existing
        }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("book2visual-keygen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let privURL = tmpDir.appendingPathComponent("id_ed25519")
        let pubURL = tmpDir.appendingPathComponent("id_ed25519.pub")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: keygenPath)
        proc.arguments = ["-t", "ed25519", "-N", "", "-C", "book2visual", "-f", privURL.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw KeychainError.keygenFailed(String(describing: error))
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
            throw KeychainError.keygenFailed(msg)
        }

        let privData = try Data(contentsOf: privURL)
        let pubString = (try? String(contentsOf: pubURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        try store.setData(privData, for: KeychainStore.sshPrivateKeyAccount)
        try store.set(pubString, for: SSHKeyManager.publicKeyAccount)
        return pubString
    }

    /// Materialize the private key to `path` with 0600 perms for ssh to read.
    /// Returns the path. Throws if no private key is stored.
    @discardableResult
    public func materializePrivateKey(to path: String) throws -> String {
        guard let data = try store.getData(KeychainStore.sshPrivateKeyAccount) else {
            throw SSHTunnelError.missingKey
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }
}
