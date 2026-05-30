import Foundation
import Observation

/// A single line in the live log panel.
public struct LogLine: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let text: String
    public init(text: String, timestamp: Date = Date()) {
        self.text = text
        self.timestamp = timestamp
    }
}

public enum RunPhase: Equatable, Sendable {
    case idle
    case submitting
    case running
    case completed
    case cancelled
    case failed(String)
}

/// Owns the Run screen: text, characters, modes, submit, live log, progress,
/// cancel, and completion -> load pages.
@MainActor
@Observable
public final class RunViewModel {
    // Inputs
    public var text: String = ""
    public var characters: [CharacterInput] = [CharacterInput(name: "")]
    public var vramMode: VRAMMode = .concurrent
    public var consistencyMode: ConsistencyMode = .kontext

    // Live state
    public private(set) var phase: RunPhase = .idle
    public private(set) var logLines: [LogLine] = []
    public private(set) var progressFraction: Double = 0
    public private(set) var scenesComplete: Int = 0
    public private(set) var totalScenes: Int?
    public private(set) var currentJobId: String?
    public private(set) var pages: [URL] = []
    public var lastError: String?

    private let client: JobClient
    private let outputStore: OutputStore
    private var streamTask: Task<Void, Never>?
    /// Called when a job finishes successfully (for notifications / auto-open viewer).
    public var onCompletion: (@MainActor ([URL]) -> Void)?

    public init(client: JobClient, outputStore: OutputStore) {
        self.client = client
        self.outputStore = outputStore
    }

    // MARK: Derived UI state

    public var wordCount: Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
    public var charCount: Int { text.count }

    public var validCharacters: [CharacterInput] {
        characters.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Run is enabled only when instance Running + text non-empty + >= 1 character.
    public func canRun(instanceRunning: Bool) -> Bool {
        instanceRunning
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !validCharacters.isEmpty
            && phase != .submitting
            && phase != .running
    }

    public var isRunning: Bool { phase == .running || phase == .submitting }

    // MARK: Character table

    public func addCharacter() {
        characters.append(CharacterInput(name: ""))
    }

    public func removeCharacter(at offsets: IndexSet) {
        characters.remove(atOffsets: offsets)
        if characters.isEmpty { characters = [CharacterInput(name: "")] }
    }

    /// Validate the tunnel + service by calling /health.
    public func healthCheck() async throws -> HealthStatus {
        try await client.health()
    }

    // MARK: Submit / run

    public func makeRequest() -> JobRequest {
        let cleaned = validCharacters.map { c -> CharacterInput in
            let hint = c.raceHint?.trimmingCharacters(in: .whitespaces)
            return CharacterInput(
                id: c.id,
                name: c.name.trimmingCharacters(in: .whitespaces),
                raceHint: (hint?.isEmpty == false) ? hint : nil
            )
        }
        return JobRequest(
            text: text,
            characters: cleaned,
            vramMode: vramMode,
            consistencyMode: consistencyMode
        )
    }

    private func log(_ message: String) {
        logLines.append(LogLine(text: message))
    }

    public func run() async {
        guard phase != .running && phase != .submitting else { return }
        phase = .submitting
        lastError = nil
        logLines.removeAll()
        pages.removeAll()
        progressFraction = 0
        scenesComplete = 0
        totalScenes = nil

        let request = makeRequest()
        let jobId: String
        do {
            log("Submitting job…")
            jobId = try await client.submit(request)
            currentJobId = jobId
            log("Job accepted: \(jobId)")
            phase = .running
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = message
            log("Submit failed: \(message)")
            phase = .failed(message)
            return
        }

        // Consume the stream in a cancellable child task so cancel() can stop it.
        let task: Task<Void, Never> = Task {
            await self.consumeStream(jobId: jobId)
        }
        streamTask = task
        await task.value
        streamTask = nil
    }

    private func consumeStream(jobId: String) async {
        let stream = client.streamEvents(jobId: jobId)
        do {
            for try await event in stream {
                if Task.isCancelled { return }
                handle(event)
                if event.type == .jobError {
                    let message = event.errorCode.map { "[\($0)] \(event.message)" } ?? event.message
                    lastError = message
                    phase = .failed(message)
                    return
                }
                if event.type == .jobComplete {
                    guard phase == .running else { return }
                    await finishSuccessfully(jobId: jobId, event: event)
                    return
                }
            }
            // Stream ended without a terminal event.
            if phase == .running {
                phase = .failed("Stream ended without a terminal event.")
                lastError = "Stream ended unexpectedly."
            }
        } catch is CancellationError {
            // handled by cancel()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            if phase == .running {
                lastError = message
                log("Stream error: \(message)")
                phase = .failed(message)
            }
        }
    }

    private func handle(_ event: ProgressEvent) {
        log(event.message)
        if let total = event.totalScenes { totalScenes = total }
        if event.type == .sceneComplete, let idx = event.sceneIndex {
            scenesComplete = idx + 1
        }
        if let fraction = event.progressFraction {
            progressFraction = fraction
        }
    }

    private func finishSuccessfully(jobId: String, event: ProgressEvent) async {
        progressFraction = 1.0
        if let total = totalScenes { scenesComplete = total }
        log("Downloading output…")
        do {
            let dir = try await client.downloadOutput(jobId: jobId)
            let loaded = outputStore.pages(in: dir)
            pages = loaded
            phase = .completed
            log("Loaded \(loaded.count) page(s).")
            onCompletion?(loaded)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            lastError = message
            log("Download failed: \(message)")
            phase = .failed(message)
        }
    }

    public func cancel() async {
        guard let jobId = currentJobId, phase == .running else { return }
        log("Cancelling…")
        // Set the terminal phase first so the (cancelled) stream loop, which guards
        // its state changes on `phase == .running`, cannot overwrite it.
        phase = .cancelled
        streamTask?.cancel()
        do {
            try await client.cancel(jobId: jobId)
        } catch {
            log("Cancel request failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }
}
