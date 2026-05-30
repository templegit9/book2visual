import SwiftUI

/// Paste text + character table + mode controls + run/cancel + live log + progress.
public struct RunView: View {
    @Bindable var viewModel: RunViewModel
    var appState: AppState
    var onCompleted: () -> Void

    public init(viewModel: RunViewModel, appState: AppState, onCompleted: @escaping () -> Void) {
        self.viewModel = viewModel
        self.appState = appState
        self.onCompleted = onCompleted
    }

    private var instanceRunning: Bool { appState.instanceStatus.isRunning }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            storyEditor
            characterTable
            modeControls
            controls
            logPanel
        }
        .padding()
        .navigationTitle("Run")
        .onChange(of: viewModel.phase) { _, newPhase in
            if newPhase == .completed { onCompleted() }
        }
    }

    private var storyEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Story text").font(.headline)
            TextEditor(text: $viewModel.text)
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("Story text editor")
            Text("\(viewModel.wordCount) words · \(viewModel.charCount) characters")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var characterTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Characters").font(.headline)
                Spacer()
                Button {
                    viewModel.addCharacter()
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add character")
            }
            ForEach($viewModel.characters) { $character in
                HStack {
                    TextField("Name", text: $character.name)
                        .accessibilityLabel("Character name")
                    TextField(
                        "race/appearance hint (e.g. human, elf)",
                        text: Binding(
                            get: { character.raceHint ?? "" },
                            set: { character.raceHint = $0 }
                        )
                    )
                    .accessibilityLabel("Character race or appearance hint")
                    Button {
                        if let idx = viewModel.characters.firstIndex(where: { $0.id == character.id }) {
                            viewModel.removeCharacter(at: IndexSet(integer: idx))
                        }
                    } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove character")
                }
            }
        }
    }

    private var modeControls: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading) {
                Text("VRAM mode").font(.subheadline)
                Picker("VRAM mode", selection: $viewModel.vramMode) {
                    ForEach(VRAMMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help(viewModel.vramMode.tooltip)
                .accessibilityLabel("VRAM mode")
            }
            VStack(alignment: .leading) {
                Text("Consistency mode").font(.subheadline)
                Picker("Consistency mode", selection: $viewModel.consistencyMode) {
                    ForEach(ConsistencyMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help(viewModel.consistencyMode.tooltip)
                .accessibilityLabel("Consistency mode")
            }
        }
    }

    private var controls: some View {
        HStack {
            Button {
                Task { await viewModel.run() }
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .disabled(!viewModel.canRun(instanceRunning: instanceRunning))
            .accessibilityLabel("Run adaptation")

            if viewModel.isRunning {
                Button(role: .destructive) {
                    Task { await viewModel.cancel() }
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .accessibilityLabel("Cancel job")
            }

            Spacer()

            if let total = viewModel.totalScenes {
                Text("\(viewModel.scenesComplete)/\(total) scenes")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var progressBar: some View {
        ProgressView(value: viewModel.progressFraction)
            .progressViewStyle(.linear)
            .accessibilityLabel("Job progress")
            .accessibilityValue("\(Int(viewModel.progressFraction * 100)) percent")
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.isRunning || viewModel.progressFraction > 0 {
                progressBar
            }
            Text("Log").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.logLines) { line in
                            Text(line.text)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(6)
                }
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: viewModel.logLines.count) { _, _ in
                    if let last = viewModel.logLines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .accessibilityLabel("Live log")
            if let error = viewModel.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption)
            }
        }
    }
}
