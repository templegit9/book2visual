import Foundation

/// Manages the App Support outputs directory and enumerates PNG pages.
/// Layout: ~/Library/Application Support/Book2Visual/outputs/<job-id>/
public struct OutputStore: @unchecked Sendable {
    private let root: URL
    private let fileManager: FileManager

    public init(root: URL? = nil, fileManager: FileManager = .default) {
        if let root {
            self.root = root
        } else {
            let base = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
            self.root = base
                .appendingPathComponent("Book2Visual", isDirectory: true)
                .appendingPathComponent("outputs", isDirectory: true)
        }
        self.fileManager = fileManager
    }

    public var outputsRoot: URL { root }

    public func directory(for jobId: String) -> URL {
        root.appendingPathComponent(jobId, isDirectory: true)
    }

    /// Save the zip bytes and unzip into the job's directory. Returns that dir.
    @discardableResult
    public func saveAndUnzip(zipData: Data, jobId: String) throws -> URL {
        let dir = directory(for: jobId)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("output.zip")
        try zipData.write(to: zipURL, options: [.atomic])
        try unzip(zipURL, into: dir)
        return dir
    }

    /// Enumerate PNG pages for a job in sorted (natural) order.
    public func pages(for jobId: String) -> [URL] {
        pages(in: directory(for: jobId))
    }

    /// Enumerate PNG pages in a directory (recursively) in sorted order.
    public func pages(in dir: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var pngs: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "png" {
            pngs.append(url)
        }
        return pngs.sorted { lhs, rhs in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    public func zipURL(for jobId: String) -> URL {
        directory(for: jobId).appendingPathComponent("output.zip")
    }

    private func unzip(_ zipURL: URL, into dir: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", zipURL.path, "-d", dir.path]
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unzip failed"
            throw JobError.decoding("unzip failed: \(msg)")
        }
    }
}
