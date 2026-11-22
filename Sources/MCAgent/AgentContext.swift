import Foundation
import MCCatalog
import MCGeneration
import MCLibrary

/// One image model the chat agent may choose (plan KTD3). `key` is the opaque token the reply schema offers; `guide` is
/// the family's `AgentGuides` text so the LLM can pick by speed and look.
public struct AgentModelOption: Sendable, Equatable {
    /// Where the model stands: installed, or signed-catalog and offered for download (D60).
    public enum Source: Sendable, Equatable {
        /// Installed and selectable.
        case installed(InstalledModel)
        /// Signed-catalog, fits this Mac, not installed: naming it in a plan proposes its download (D60).
        case offered(id: String, name: String, sizeBytes: Int64)
    }

    public let key: String
    public let source: Source
    public let family: ModelFamily
    public let guide: String

    public init(key: String, source: Source, family: ModelFamily, guide: String) {
        self.key = key
        self.source = source
        self.family = family
        self.guide = guide
    }

    /// The installed model the option wraps, or nil when it is a download offer.
    public var installedModel: InstalledModel? {
        guard case .installed(let model) = source else { return nil }
        return model
    }
}

/// One LoRA the chat agent may choose. A `.shelf` option is curated but not installed, so choosing it turns the plan
/// into a download proposal instead of a generation (D60).
public struct AgentLoRAOption: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Installed; the entry's `weight` is ignored, the resolver sets it from the plan's scale.
        case installed(LoRAStackEntry)
        /// Curated, not installed.
        case shelf(sha256: String, name: String, sizeBytes: Int64)
    }

    public let key: String
    /// The model options this LoRA fits.
    public let modelKeys: [String]
    /// What it does: the shelf role text or, for a user-installed LoRA, its name.
    public let about: String
    public let triggerWords: [String]
    public let usualScale: Double
    /// The shelf entry's `nsfw` flag; gated by `AgentContext.adultOptIn`.
    public let isCuratedAdult: Bool
    public let source: Source

    public init(
        key: String, modelKeys: [String], about: String, triggerWords: [String], usualScale: Double,
        isCuratedAdult: Bool, source: Source
    ) {
        self.key = key
        self.modelKeys = modelKeys
        self.about = about
        self.triggerWords = triggerWords
        self.usualScale = usualScale
        self.isCuratedAdult = isCuratedAdult
        self.source = source
    }
}

/// The image the user is talking about, when there is one: the settings it was made with and its JPEG bytes for
/// vision (plan KTD13). `isExplicit` marks a referent the user chose (the open large image, a single selection, a
/// pin) against the implicit newest-conversation-image fallback, which the prompt labels differently.
public struct AgentReferent: Sendable, Equatable {
    public let settings: ImageSettings
    public let jpeg: Data?
    public let isExplicit: Bool

    public init(settings: ImageSettings, jpeg: Data?, isExplicit: Bool) {
        self.settings = settings
        self.jpeg = jpeg
        self.isExplicit = isExplicit
    }
}

/// One spoken turn of the conversation, oldest first.
public struct AgentTurn: Sendable, Equatable {
    public enum Speaker: Sendable, Equatable {
        case user
        case agent
    }

    public let speaker: Speaker
    public let text: String

    public init(speaker: Speaker, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// Everything a planning turn needs: the conversation, the image being discussed, and the options the agent may pick.
/// `turns` is oldest first and its last entry is the user's new message.
public struct AgentContext: Sendable, Equatable {
    public var turns: [AgentTurn]
    public var referent: AgentReferent?
    public var models: [AgentModelOption]
    public var loras: [AgentLoRAOption]
    /// Whether a follow-up question is allowed right now (false after the agent already asked once).
    public var mayAsk: Bool
    /// Whether the user opted in to curated adult LoRAs (D61).
    public var adultOptIn: Bool

    public init(
        turns: [AgentTurn], referent: AgentReferent?, models: [AgentModelOption], loras: [AgentLoRAOption],
        mayAsk: Bool, adultOptIn: Bool
    ) {
        self.turns = turns
        self.referent = referent
        self.models = models
        self.loras = loras
        self.mayAsk = mayAsk
        self.adultOptIn = adultOptIn
    }
}
