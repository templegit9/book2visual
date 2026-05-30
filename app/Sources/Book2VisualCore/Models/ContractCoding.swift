import Foundation

/// Shared JSON coders configured to produce/consume the exact contract wire shape.
/// CodingKeys on each model handle snake_case, so we do NOT use a global key
/// strategy here (that would double-convert).
public enum ContractCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
