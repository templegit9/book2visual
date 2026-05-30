import SwiftUI

/// Instance status indicator + Start/Stop + Prepare Environment + settings gear.
public struct SetupView: View {
    @Bindable var viewModel: InstanceViewModel
    var appState: AppState
    let env: AppEnvironment
    @State private var showSettings = false

    public init(viewModel: InstanceViewModel, appState: AppState, env: AppEnvironment) {
        self.viewModel = viewModel
        self.appState = appState
        self.env = env
    }

    private var statusColor: Color {
        switch viewModel.status.light {
        case .grey: return .gray
        case .yellow: return .yellow
        case .green: return .green
        case .red: return .red
        }
    }

    public var body: some View {
        Form {
            Section("Instance") {
                HStack(spacing: 10) {
                    Circle().fill(statusColor).frame(width: 14, height: 14)
                    VStack(alignment: .leading) {
                        Text(viewModel.status.label).font(.headline)
                        Text("Updated \(viewModel.statusTimestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if viewModel.isBusy { ProgressView().controlSize(.small) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Instance status \(viewModel.status.label)"))

                HStack {
                    Button("Start") { Task { await viewModel.start() } }
                        .disabled(viewModel.isBusy || viewModel.status.isRunning)
                        .accessibilityLabel("Start instance")
                    Button("Stop") { Task { await viewModel.stop() } }
                        .disabled(viewModel.isBusy || !viewModel.status.isRunning)
                        .accessibilityLabel("Stop instance")
                }
            }

            Section("One-time setup") {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        Task { await viewModel.prepareEnvironment() }
                    } label: {
                        Label("Prepare Environment", systemImage: "wand.and.stars")
                    }
                    .disabled(viewModel.isBusy)
                    .accessibilityLabel("Prepare environment: provision, bootstrap, snapshot")

                    Text("Provisions the GPU instance, bootstraps the pipeline, and snapshots it for fast future starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let phase = viewModel.preparePhase {
                        Label(phase, systemImage: "hourglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = viewModel.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(error)")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .toolbar {
            ToolbarItem {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Open settings")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(appState: appState, env: env)
        }
    }
}
