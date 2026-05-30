import SwiftUI

public enum AppTab: String, CaseIterable, Identifiable {
    case setup = "Setup"
    case run = "Run"
    case viewer = "Viewer"

    public var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .setup: return "gearshape.2"
        case .run: return "play.rectangle"
        case .viewer: return "photo.on.rectangle.angled"
        }
    }
}

/// Sidebar/tab container for Setup, Run, Viewer.
public struct RootView: View {
    @State private var selection: AppTab = .setup
    private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var body: some View {
        NavigationSplitView {
            List(AppTab.allCases, selection: $selection) { tab in
                NavigationLink(value: tab) {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                }
                .accessibilityLabel(Text(tab.rawValue))
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                StatusIndicator(status: env.appState.instanceStatus)
                    .padding(8)
            }
        } detail: {
            switch selection {
            case .setup:
                SetupView(viewModel: env.instanceViewModel, appState: env.appState, env: env)
            case .run:
                RunView(viewModel: env.runViewModel, appState: env.appState) {
                    selection = .viewer
                }
            case .viewer:
                ViewerView(viewModel: env.runViewModel)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onChange(of: env.runViewModel.phase) { _, newPhase in
            if newPhase == .completed { selection = .viewer }
        }
    }
}

/// Compact traffic-light status row (grey/yellow/green/red).
public struct StatusIndicator: View {
    let status: InstanceStatus

    public init(status: InstanceStatus) { self.status = status }

    private var color: Color {
        switch status.light {
        case .grey: return .gray
        case .yellow: return .yellow
        case .green: return .green
        case .red: return .red
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Instance status: \(status.label)"))
    }
}
