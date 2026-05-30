import SwiftUI
import UniformTypeIdentifiers

/// Settings: Thunder token (write-only, Keychain), SSH key path, FastAPI port,
/// and a Validate Connection button (tunnel + /health).
public struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var appState: AppState
    let env: AppEnvironment

    @State private var tokenField: String = ""
    @State private var sshKeyPath: String = ""
    @State private var fastAPIPort: String = "8000"
    @State private var validationMessage: String?
    @State private var validationOK = false
    @State private var isValidating = false
    @State private var savedToken = false

    public init(appState: AppState, env: AppEnvironment) {
        self.appState = appState
        self.env = env
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("ThunderCompute") {
                    SecureField("API token", text: $tokenField, prompt: Text("Paste token (write-only)"))
                        .accessibilityLabel("Thunder API token")
                    if appState.hasThunderToken() {
                        Label("A token is stored in the Keychain.", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if savedToken {
                        Label("Token saved.", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.green)
                    }
                }

                Section("SSH") {
                    HStack {
                        TextField("SSH private key path", text: $sshKeyPath)
                            .accessibilityLabel("SSH key path")
                        Button("Choose…") { chooseKey() }
                            .accessibilityLabel("Choose SSH key file")
                    }
                }

                Section("Pipeline") {
                    TextField("FastAPI port", text: $fastAPIPort)
                        .accessibilityLabel("FastAPI port")
                }

                Section {
                    Button {
                        Task { await validate() }
                    } label: {
                        HStack {
                            if isValidating { ProgressView().controlSize(.small) }
                            Text("Validate Connection")
                        }
                    }
                    .disabled(isValidating)
                    .accessibilityLabel("Validate connection: tunnel and health")

                    if let msg = validationMessage {
                        Label(msg, systemImage: validationOK ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(validationOK ? .green : .red)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 460)
        .onAppear(perform: loadCurrent)
    }

    private func loadCurrent() {
        sshKeyPath = appState.settings.sshKeyPath ?? ""
        fastAPIPort = String(appState.settings.fastAPIPort)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            sshKeyPath = url.path
        }
    }

    private func save() {
        if !tokenField.isEmpty {
            try? appState.saveThunderToken(tokenField)
            savedToken = true
            tokenField = ""
        }
        appState.settings.sshKeyPath = sshKeyPath.isEmpty ? nil : sshKeyPath
        appState.settings.fastAPIPort = Int(fastAPIPort) ?? 8000
        appState.persistSettings()
        dismiss()
    }

    private func validate() async {
        isValidating = true
        validationMessage = nil
        defer { isValidating = false }
        do {
            let health = try await env.runViewModel.healthCheck()
            validationOK = health.isOK
            validationMessage = health.isOK
                ? "Connected. Models loaded: \(health.modelsLoaded)\(health.stub == true ? " (stub)" : "")"
                : "Service responded but status was \(health.status)."
        } catch {
            validationOK = false
            validationMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
