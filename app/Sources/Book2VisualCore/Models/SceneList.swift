import Foundation

/// Internal text-stage output. Mirrors `contract/schemas/scene_list.schema.json`.
/// Not returned to the app directly by the contract, but modeled so future
/// history/inspection UI can decode it byte-compatibly.
public struct SceneList: Codable, Equatable, Sendable {
    public struct Character: Codable, Equatable, Sendable {
        public var name: String
        public var appearancePrompt: String
        public var refSheetPrompt: String

        public init(name: String, appearancePrompt: String, refSheetPrompt: String) {
            self.name = name
            self.appearancePrompt = appearancePrompt
            self.refSheetPrompt = refSheetPrompt
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case appearancePrompt = "appearance_prompt"
            case refSheetPrompt = "ref_sheet_prompt"
        }
    }

    public struct Scene: Codable, Equatable, Sendable {
        public var index: Int
        public var title: String
        public var imagePrompt: String
        public var charactersPresent: [String]
        public var caption: String
        public var pivotal: Bool

        public init(
            index: Int,
            title: String,
            imagePrompt: String,
            charactersPresent: [String],
            caption: String,
            pivotal: Bool
        ) {
            self.index = index
            self.title = title
            self.imagePrompt = imagePrompt
            self.charactersPresent = charactersPresent
            self.caption = caption
            self.pivotal = pivotal
        }

        private enum CodingKeys: String, CodingKey {
            case index
            case title
            case imagePrompt = "image_prompt"
            case charactersPresent = "characters_present"
            case caption
            case pivotal
        }
    }

    public var characters: [Character]
    public var scenes: [Scene]

    public init(characters: [Character], scenes: [Scene]) {
        self.characters = characters
        self.scenes = scenes
    }
}
