import Foundation

/// User-configurable, non-secret settings (secrets live in Keychain).
public struct AppSettings: Codable, Equatable, Sendable {
    public var fastAPIPort: Int
    public var localTunnelPort: Int
    public var sshKeyPath: String?
    public var instanceId: String?

    public init(
        fastAPIPort: Int = 8000,
        localTunnelPort: Int = 8000,
        sshKeyPath: String? = nil,
        instanceId: String? = nil
    ) {
        self.fastAPIPort = fastAPIPort
        self.localTunnelPort = localTunnelPort
        self.sshKeyPath = sshKeyPath
        self.instanceId = instanceId
    }
}

/// Persists `AppSettings` to UserDefaults (secrets excluded).
public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let key = "book2visual.settings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private var settings: AppSettings
    private let lock = NSLock()
    public init(_ settings: AppSettings = AppSettings()) { self.settings = settings }
    public func load() -> AppSettings { lock.lock(); defer { lock.unlock() }; return settings }
    public func save(_ settings: AppSettings) { lock.lock(); self.settings = settings; lock.unlock() }
}
