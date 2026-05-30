import Foundation

/// Drives a scripted ProgressEvent sequence + a tiny local zip so the app and
/// tests run with no network. Mirrors the real contract event sequence.
public final class MockJobClient: JobClient, @unchecked Sendable {
    public enum Scenario: Sendable {
        case success
        case error(code: String, message: String)
        case alreadyRunning
    }

    private let scenario: Scenario
    private let totalScenes: Int
    private let outputStore: OutputStore
    private let interEventDelay: UInt64

    /// - Parameters:
    ///   - interEventDelay: nanoseconds between scripted events (0 in tests).
    public init(
        scenario: Scenario = .success,
        totalScenes: Int = 4,
        outputStore: OutputStore,
        interEventDelay: UInt64 = 0
    ) {
        self.scenario = scenario
        self.totalScenes = totalScenes
        self.outputStore = outputStore
        self.interEventDelay = interEventDelay
    }

    public func health() async throws -> HealthStatus {
        HealthStatus(status: "ok", modelsLoaded: true, stub: true)
    }

    public func submit(_ request: JobRequest) async throws -> String {
        if case .alreadyRunning = scenario { throw JobError.jobAlreadyRunning }
        return UUID().uuidString
    }

    public func streamEvents(jobId: String) -> AsyncThrowingStream<ProgressEvent, Error> {
        let events = scriptedEvents(jobId: jobId)
        let delay = interEventDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    if Task.isCancelled { continuation.finish(); return }
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(jobId: String) async throws {
        // No-op in mock; a cancelled stream simply stops being consumed.
    }

    public func downloadOutput(jobId: String) async throws -> URL {
        if case .error = scenario { throw JobError.noOutput }
        let zip = try Self.makeTinyZip(pageNames: pageNames())
        return try outputStore.saveAndUnzip(zipData: zip, jobId: jobId)
    }

    // MARK: - Scripting

    private func pageNames() -> [String] {
        (0..<totalScenes).map { String(format: "page_%03d.png", $0) }
    }

    private func ts() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func scriptedEvents(jobId: String) -> [ProgressEvent] {
        var out: [ProgressEvent] = []
        out.append(ProgressEvent(type: .jobAccepted, jobId: jobId, message: "Job accepted.", ts: ts()))
        out.append(ProgressEvent(type: .stageUpdate, jobId: jobId, message: "Extracting scenes…", ts: ts()))

        if case let .error(code, message) = scenario {
            // Fail partway through.
            out.append(ProgressEvent(type: .sceneStart, jobId: jobId, sceneIndex: 0, totalScenes: totalScenes, message: "Scene 1/\(totalScenes) starting.", ts: ts()))
            out.append(ProgressEvent(type: .jobError, jobId: jobId, message: message, ts: ts(), errorCode: code))
            return out
        }

        for i in 0..<totalScenes {
            out.append(ProgressEvent(type: .sceneStart, jobId: jobId, sceneIndex: i, totalScenes: totalScenes, message: "Scene \(i + 1)/\(totalScenes) starting.", ts: ts()))
            out.append(ProgressEvent(type: .sceneComplete, jobId: jobId, sceneIndex: i, totalScenes: totalScenes, message: "Scene \(i + 1)/\(totalScenes) panel rendered.", ts: ts()))
        }
        out.append(ProgressEvent(type: .jobComplete, jobId: jobId, sceneIndex: nil, totalScenes: totalScenes, message: "Job complete.", ts: ts(), pages: pageNames().count))
        return out
    }

    // MARK: - Tiny zip builder (no external deps)

    /// Build a minimal valid ZIP (stored, no compression) containing 1x1 PNGs.
    static func makeTinyZip(pageNames: [String]) throws -> Data {
        var entries: [(name: String, data: Data)] = []
        for name in pageNames {
            entries.append((name, onePixelPNG))
        }
        return ZipWriter.build(entries: entries)
    }

    /// A valid 1x1 transparent PNG.
    static let onePixelPNG: Data = {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        return Data(base64Encoded: base64) ?? Data()
    }()
}

/// Minimal "stored" (uncompressed) ZIP writer — enough for /usr/bin/unzip.
enum ZipWriter {
    static func build(entries: [(name: String, data: Data)]) -> Data {
        var output = Data()
        var central = Data()
        var offset: UInt32 = 0

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)

            // Local file header.
            var local = Data()
            local.appendLE32(0x04034b50)         // signature
            local.appendLE16(20)                 // version needed
            local.appendLE16(0)                  // flags
            local.appendLE16(0)                  // method = stored
            local.appendLE16(0)                  // mod time
            local.appendLE16(0)                  // mod date
            local.appendLE32(crc)                // crc-32
            local.appendLE32(size)               // compressed size
            local.appendLE32(size)               // uncompressed size
            local.appendLE16(UInt16(nameBytes.count))
            local.appendLE16(0)                  // extra len
            local.append(contentsOf: nameBytes)
            local.append(entry.data)

            // Central directory header.
            central.appendLE32(0x02014b50)
            central.appendLE16(20)               // version made by
            central.appendLE16(20)               // version needed
            central.appendLE16(0)                // flags
            central.appendLE16(0)                // method
            central.appendLE16(0)                // time
            central.appendLE16(0)                // date
            central.appendLE32(crc)
            central.appendLE32(size)
            central.appendLE32(size)
            central.appendLE16(UInt16(nameBytes.count))
            central.appendLE16(0)                // extra len
            central.appendLE16(0)                // comment len
            central.appendLE16(0)                // disk number start
            central.appendLE16(0)                // internal attrs
            central.appendLE32(0)                // external attrs
            central.appendLE32(offset)           // local header offset
            central.append(contentsOf: nameBytes)

            offset += UInt32(local.count)
            output.append(local)
        }

        let centralOffset = offset
        let centralSize = UInt32(central.count)
        output.append(central)

        // End of central directory record.
        var eocd = Data()
        eocd.appendLE32(0x06054b50)
        eocd.appendLE16(0)                        // disk number
        eocd.appendLE16(0)                        // central dir disk
        eocd.appendLE16(UInt16(entries.count))   // entries on disk
        eocd.appendLE16(UInt16(entries.count))   // total entries
        eocd.appendLE32(centralSize)
        eocd.appendLE32(centralOffset)
        eocd.appendLE16(0)                        // comment len
        output.append(eocd)

        return output
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }
    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
