import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// PNG page browser with prev/next + arrow keys, page X/total, Export ZIP.
public struct ViewerView: View {
    @Bindable var viewModel: RunViewModel
    @State private var index: Int = 0

    public init(viewModel: RunViewModel) {
        self.viewModel = viewModel
    }

    private var pages: [URL] { viewModel.pages }

    public var body: some View {
        VStack(spacing: 12) {
            if pages.isEmpty {
                ContentUnavailableView(
                    "No pages yet",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Run an adaptation to see manga pages here.")
                )
            } else {
                pageImage
                controls
            }
        }
        .padding()
        .navigationTitle("Viewer")
        .toolbar {
            ToolbarItem {
                Button {
                    exportZip()
                } label: { Label("Export ZIP", systemImage: "square.and.arrow.up") }
                .disabled(pages.isEmpty)
                .accessibilityLabel("Export pages as ZIP")
            }
        }
        .onChange(of: pages.count) { _, _ in index = 0 }
    }

    @ViewBuilder
    private var pageImage: some View {
        let clamped = min(max(index, 0), max(pages.count - 1, 0))
        if pages.indices.contains(clamped), let image = NSImage(contentsOf: pages[clamped]) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Page \(clamped + 1) of \(pages.count)")
        } else {
            Color.secondary.opacity(0.1)
        }
    }

    private var controls: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(index <= 0)
                .accessibilityLabel("Previous page")
            Text("Page \(min(index + 1, pages.count)) / \(pages.count)")
                .monospacedDigit()
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(index >= pages.count - 1)
                .accessibilityLabel("Next page")
        }
    }

    private func step(_ delta: Int) {
        index = min(max(index + delta, 0), max(pages.count - 1, 0))
    }

    private func exportZip() {
        guard let first = pages.first else { return }
        let jobDir = first.deletingLastPathComponent()
        let zipURL = jobDir.appendingPathComponent("output.zip")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.zip]
        panel.nameFieldStringValue = Self.defaultZipName()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        // Prefer the original output.zip if present; else re-zip the page dir.
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try? FileManager.default.copyItem(at: zipURL, to: dest)
        } else {
            try? Self.zipDirectory(jobDir, to: dest)
        }
    }

    static func defaultZipName(slug: String = "adaptation", date: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "book2visual-\(slug)-\(df.string(from: date)).zip"
    }

    static func zipDirectory(_ dir: URL, to dest: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = dir
        proc.arguments = ["-r", "-q", dest.path, "."]
        try proc.run()
        proc.waitUntilExit()
    }
}
