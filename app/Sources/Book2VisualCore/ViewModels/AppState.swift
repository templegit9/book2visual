import Foundation
import Observation

/// Top-level shared app state: instance status mirror + settings.
@MainActor
@Observable
public final class AppState {
    public var instanceStatus: InstanceStatus = .stopped
    public var statusTimestamp: Date = Date()
    public var settings: AppSettings

    private let settingsStore: SettingsStore
    private let secretStore: SecretStore

    public init(
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        secretStore: SecretStore = KeychainStore()
    ) {
        self.settingsStore = settingsStore
        self.secretStore = secretStore
        self.settings = settingsStore.load()
    }

    public func updateStatus(_ status: InstanceStatus) {
        instanceStatus = status
        statusTimestamp = Date()
    }

    public func persistSettings() {
        settingsStore.save(settings)
    }

    // MARK: Secrets

    public func saveThunderToken(_ token: String) throws {
        try secretStore.set(token, for: KeychainStore.thunderTokenAccount)
    }

    public func hasThunderToken() -> Bool {
        (try? secretStore.get(KeychainStore.thunderTokenAccount))?.isEmpty == false
    }

    public func thunderToken() throws -> String {
        guard let token = try secretStore.get(KeychainStore.thunderTokenAccount), !token.isEmpty else {
            throw ThunderError.missingToken
        }
        return token
    }

    /// Traffic-light for the menu-bar indicator.
    public var statusLight: InstanceStatus.Light { instanceStatus.light }
}
