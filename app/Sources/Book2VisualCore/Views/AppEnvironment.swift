import Foundation

/// Composition root: wires services + view models. A `.mock` factory lets the
/// app and previews run fully offline against `MockJobClient`/`MockInstanceManager`.
@MainActor
public final class AppEnvironment {
    public let appState: AppState
    public let instanceViewModel: InstanceViewModel
    public let runViewModel: RunViewModel
    public let outputStore: OutputStore

    public init(
        appState: AppState,
        instanceManager: any InstanceManager,
        jobClient: JobClient,
        outputStore: OutputStore,
        tunnel: SSHTunnel? = nil
    ) {
        self.appState = appState
        self.outputStore = outputStore
        self.instanceViewModel = InstanceViewModel(
            manager: instanceManager, appState: appState, tunnel: tunnel
        )
        self.runViewModel = RunViewModel(client: jobClient, outputStore: outputStore)
    }

    /// Fully offline environment for previews/dev (no network, no GPU).
    public static func mock() -> AppEnvironment {
        let outputStore = OutputStore()
        let appState = AppState(
            settingsStore: InMemorySettingsStore(),
            secretStore: InMemorySecretStore()
        )
        return AppEnvironment(
            appState: appState,
            instanceManager: MockInstanceManager(),
            jobClient: MockJobClient(outputStore: outputStore, interEventDelay: 250_000_000),
            outputStore: outputStore
        )
    }

    /// Live environment wired to the Thunder REST control plane + tunnelled JobClient.
    /// `localPort` should match the SSH tunnel local forward.
    public static func live(localPort: Int = 8000) -> AppEnvironment {
        let outputStore = OutputStore()
        let secretStore = KeychainStore()
        let appState = AppState(
            settingsStore: UserDefaultsSettingsStore(),
            secretStore: secretStore
        )
        let keyManager = SSHKeyManager(store: secretStore)
        let client = ThunderClient {
            try secretStore.get(KeychainStore.thunderTokenAccount) ?? ""
        }
        let manager = ThunderRESTInstanceManager(
            client: client,
            instanceId: appState.settings.instanceId
        ) {
            try keyManager.ensureKeyPair()
        }
        let jobClient = HTTPJobClient(localPort: localPort, outputStore: outputStore)
        // The tunnel forwards localhost:<localPort> -> instance 127.0.0.1:<fastAPIPort>.
        // InstanceViewModel opens it once the instance is Running; jobClient then
        // reaches the pipeline over localhost.
        let tunnel = SSHTunnel()
        return AppEnvironment(
            appState: appState,
            instanceManager: manager,
            jobClient: jobClient,
            outputStore: outputStore,
            tunnel: tunnel
        )
    }
}
