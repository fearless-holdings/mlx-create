import Foundation

/// The bundled one-paragraph descriptions the chat agent plans with (plan KTD4): what each model family is like and what
/// each curated LoRA role does. Decoded from `Resources/Guides.json`.
public struct AgentGuides: Sendable, Equatable {
    private let families: [String: String]
    private let loraRoles: [String: String]

    public init(families: [String: String], loraRoles: [String: String]) {
        self.families = families
        self.loraRoles = loraRoles
    }

    /// The bundled guide file. An absent or malformed resource yields empty lookups, never a crash.
    public static func bundled() -> AgentGuides {
        struct Wire: Decodable {
            let families: [String: String]?
            let loraRoles: [String: String]?
        }
        guard let url = Bundle.module.url(forResource: "Guides", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let wire = try? JSONDecoder().decode(Wire.self, from: data)
        else { return AgentGuides(families: [:], loraRoles: [:]) }
        return AgentGuides(families: wire.families ?? [:], loraRoles: wire.loraRoles ?? [:])
    }

    /// The family's planning description, or nil for a family the guide file does not know.
    public func familyGuide(_ familyID: String) -> String? {
        families[familyID]
    }

    /// A curated LoRA role's planning description, or nil for a role the guide file does not know.
    public func loraRole(_ role: String) -> String? {
        loraRoles[role]
    }
}
