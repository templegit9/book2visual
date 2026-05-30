import SwiftUI
import AppKit
import UserNotifications

/// The reusable App scene. The executable target hosts this via @main.
public struct Book2VisualScene: Scene {
    @State private var env: AppEnvironment

    public init(env: AppEnvironment? = nil) {
        // BOOK2VISUAL_MOCK=1 -> fully offline mock environment (no GPU/network).
        let resolved: AppEnvironment
        if let env {
            resolved = env
        } else if ProcessInfo.processInfo.environment["BOOK2VISUAL_MOCK"] == "1" {
            resolved = AppEnvironment.mock()
        } else {
            resolved = AppEnvironment.live()
        }
        _env = State(initialValue: resolved)
    }

    public var body: some Scene {
        WindowGroup {
            RootView(env: env)
                .onAppear {
                    requestNotificationPermission()
                    wireCompletionNotification()
                }
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Book2Visual", systemImage: menuBarSymbol) {
            MenuBarContent(appState: env.appState, instanceVM: env.instanceViewModel)
        }
    }

    private var menuBarSymbol: String {
        switch env.appState.statusLight {
        case .grey: return "circle"
        case .yellow: return "circle.dotted"
        case .green: return "circle.fill"
        case .red: return "exclamationmark.circle"
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func wireCompletionNotification() {
        env.runViewModel.onCompletion = { pages in
            let content = UNMutableNotificationContent()
            content.title = "Book2Visual"
            content.body = "Adaptation complete — \(pages.count) page(s) ready."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }
}

/// Menu-bar dropdown content with cost-awareness controls.
struct MenuBarContent: View {
    var appState: AppState
    var instanceVM: InstanceViewModel

    var body: some View {
        Text("Instance: \(appState.instanceStatus.label)")
        Divider()
        Button("Stop Instance") { Task { await instanceVM.stop() } }
            .disabled(!appState.instanceStatus.isRunning)
        Button("Refresh Status") { Task { await instanceVM.refresh() } }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
