import Foundation

/// SSE event type. Mirrors `type` in `contract/schemas/progress_event.schema.json`.
public enum ProgressEventType: String, Codable, Sendable {
    case jobAccepted = "job_accepted"
    case stageUpdate = "stage_update"
    case sceneStart = "scene_start"
    case sceneComplete = "scene_complete"
    case jobComplete = "job_complete"
    case jobError = "job_error"

    /// Terminal events end the stream (exactly one, complete XOR error).
    public var isTerminal: Bool {
        self == .jobComplete || self == .jobError
    }
}

/// A single SSE `data:` line. Mirrors `contract/schemas/progress_event.schema.json`.
public struct ProgressEvent: Codable, Equatable, Sendable {
    public var type: ProgressEventType
    public var jobId: String
    public var sceneIndex: Int?
    public var totalScenes: Int?
    public var message: String
    /// ISO-8601 timestamp string (kept as String to preserve exact wire bytes).
    public var ts: String
    /// Integer page count, present on `job_complete` (see contract). NOT filenames —
    /// page filenames come from unzipping `GET /output` via `OutputStore`.
    public var pages: Int?
    /// Set on job_error.
    public var errorCode: String?

    public init(
        type: ProgressEventType,
        jobId: String,
        sceneIndex: Int? = nil,
        totalScenes: Int? = nil,
        message: String,
        ts: String,
        pages: Int? = nil,
        errorCode: String? = nil
    ) {
        self.type = type
        self.jobId = jobId
        self.sceneIndex = sceneIndex
        self.totalScenes = totalScenes
        self.message = message
        self.ts = ts
        self.pages = pages
        self.errorCode = errorCode
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case jobId = "job_id"
        case sceneIndex = "scene_index"
        case totalScenes = "total_scenes"
        case message
        case ts
        case pages
        case errorCode = "error_code"
    }

    /// Progress fraction in [0, 1] when scene counts are known; nil otherwise.
    public var progressFraction: Double? {
        guard let total = totalScenes, total > 0 else { return nil }
        switch type {
        case .jobComplete:
            return 1.0
        case .sceneComplete:
            guard let idx = sceneIndex else { return nil }
            // scene_index is 0-based; a completed scene index i means i+1 done.
            return min(1.0, Double(idx + 1) / Double(total))
        default:
            return nil
        }
    }
}
