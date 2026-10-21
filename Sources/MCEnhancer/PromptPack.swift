import Foundation

/// One bundled prompt pack (KTD8), keyed by family id. `shape` says what the family responds to and what its
/// prompts look like. `examples` are rough-to-enhanced pairs in the format the enhancer answers in. The system
/// message is the shared rules in `PromptEnhancer` followed by this pack's shape and examples.
struct PromptPack: Decodable, Equatable, Sendable {
    struct Example: Decodable, Equatable, Sendable {
        let rough: String
        let enhanced: String
    }

    let shape: String
    let examples: [Example]

    /// The pack at `Resources/Packs/<familyID>.json`, or nil when none ships for the family or the file cannot be read.
    static func bundled(familyID: String) -> PromptPack? {
        guard let url = Bundle.module.url(forResource: familyID, withExtension: "json", subdirectory: "Packs"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(PromptPack.self, from: data)
    }
}
