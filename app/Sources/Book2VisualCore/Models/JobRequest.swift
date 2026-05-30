import Foundation

/// VRAM execution strategy on the GPU instance.
/// Mirrors `vram_mode` in `contract/schemas/job_request.schema.json`.
public enum VRAMMode: String, Codable, CaseIterable, Sendable {
    /// Both models resident (requires >= 80GB).
    case concurrent
    /// LLM then FLUX, swapping VRAM in between.
    case sequenced

    public var displayName: String {
        switch self {
        case .concurrent: return "Concurrent"
        case .sequenced: return "Sequenced"
        }
    }

    public var tooltip: String {
        switch self {
        case .concurrent:
            return "Both the LLM and FLUX stay resident in VRAM. Fastest, needs an 80GB+ GPU."
        case .sequenced:
            return "Run the LLM first, free its VRAM, then load FLUX. Slower but fits smaller GPUs."
        }
    }
}

/// Character-consistency backend.
/// Mirrors `consistency_mode` in `contract/schemas/job_request.schema.json`.
public enum ConsistencyMode: String, Codable, CaseIterable, Sendable {
    /// FLUX.1-Kontext-dev depth-1 fan-out (default).
    case kontext
    /// Per-character anime LoRA.
    case lora

    public var displayName: String {
        switch self {
        case .kontext: return "Kontext"
        case .lora: return "LoRA"
        }
    }

    public var tooltip: String {
        switch self {
        case .kontext:
            return "FLUX.1-Kontext-dev depth-1 fan-out from a reference sheet. Default."
        case .lora:
            return "Train and apply a per-character anime LoRA for stronger identity."
        }
    }
}

/// A single character supplied with the story.
/// Mirrors an item of `characters[]` in `job_request.schema.json`.
public struct CharacterInput: Codable, Equatable, Identifiable, Sendable {
    /// Local-only stable id for SwiftUI lists. Not part of the wire contract.
    public var id: UUID
    public var name: String
    /// Optional race/appearance hint, e.g. "human", "elf".
    public var raceHint: String?

    public init(id: UUID = UUID(), name: String, raceHint: String? = nil) {
        self.id = id
        self.name = name
        self.raceHint = raceHint
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case raceHint = "race_hint"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.raceHint = try c.decodeIfPresent(String.self, forKey: .raceHint)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        // Only emit race_hint when non-empty so the payload stays minimal and
        // additionalProperties:false is never tripped.
        if let raceHint, !raceHint.isEmpty {
            try c.encode(raceHint, forKey: .raceHint)
        }
    }
}

/// POST /jobs body. Mirrors `contract/schemas/job_request.schema.json`.
public struct JobRequest: Codable, Equatable, Sendable {
    public var text: String
    public var characters: [CharacterInput]
    public var vramMode: VRAMMode
    public var consistencyMode: ConsistencyMode

    public init(
        text: String,
        characters: [CharacterInput],
        vramMode: VRAMMode = .concurrent,
        consistencyMode: ConsistencyMode = .kontext
    ) {
        self.text = text
        self.characters = characters
        self.vramMode = vramMode
        self.consistencyMode = consistencyMode
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case characters
        case vramMode = "vram_mode"
        case consistencyMode = "consistency_mode"
    }
}
