import Foundation

public struct ImageSize: Sendable, Codable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// The size grid the engine snaps a requested dimension to (`clampKreaDim` / `clampFluxDim` upstream):
/// round up to a multiple of `multiple`, then clamp into `min...max`.
public struct SizeGrid: Sendable, Codable, Hashable {
    public let multiple: Int
    public let min: Int
    public let max: Int

    public init(multiple: Int, min: Int, max: Int) {
        self.multiple = multiple
        self.min = min
        self.max = max
    }
}

public struct StepsCapability: Sendable, Codable, Hashable {
    /// The engine's own default. The request omits `steps` unless the user changed it (KTD3).
    public let defaultSteps: Int
    public let min: Int
    public let max: Int

    public init(defaultSteps: Int, min: Int, max: Int) {
        self.defaultSteps = defaultSteps
        self.min = min
        self.max = max
    }
}

public struct GuidanceCapability: Sendable, Codable, Hashable {
    public let defaultValue: Double
    public let min: Double
    public let max: Double

    public init(defaultValue: Double, min: Double, max: Double) {
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
    }
}

/// One Civitai base-model label (HLD §8.4) and the size variant it names, when it names one.
public struct CivitaiBaseModel: Sendable, Codable, Hashable {
    public let label: String
    public let variant: String?

    public init(label: String, variant: String? = nil) {
        self.label = label
        self.variant = variant
    }
}

/// One verified model architecture (KTD10, D21). The UI is driven from these records only (R7, R8).
public struct ModelFamily: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    /// Values of `meta.architecture` in `GET /v1/models` that belong to this family.
    public let architectures: [String]
    public let sizeGrid: SizeGrid
    /// The only sizes the UI offers; every one lies on `sizeGrid`.
    public let sizePresets: [ImageSize]
    public let defaultSize: ImageSize
    public let steps: StepsCapability
    /// `true` when the checkpoint fixes the step count (KTD2). A fixed family sends no `steps`
    /// and shows the count as read-only.
    public let stepsAreFixed: Bool
    /// `nil` means the family ignores guidance and the control is hidden.
    public let guidance: GuidanceCapability?
    public let supportsNegativePrompt: Bool
    /// A checkpoint trait the installed pack must report before this record applies, e.g.
    /// `sample_sigmas` (KTD5). `nil` means the architecture alone is enough.
    public let requiresTrait: String?
    /// Tensor-name, shape and block-count fingerprints for LoRA files (KTD4). A file matches the family
    /// when ANY alternative matches. `nil` or empty means the family accepts no LoRAs.
    public let loraFingerprints: [LoRAFingerprint]?
    /// Civitai base-model labels this family answers to (KTD7). Empty means Browse never offers the family.
    public let civitaiBaseModels: [CivitaiBaseModel]

    public init(
        id: String, displayName: String, architectures: [String], sizeGrid: SizeGrid,
        sizePresets: [ImageSize], defaultSize: ImageSize, steps: StepsCapability,
        guidance: GuidanceCapability?, supportsNegativePrompt: Bool,
        stepsAreFixed: Bool = false, requiresTrait: String? = nil,
        loraFingerprints: [LoRAFingerprint]? = nil,
        civitaiBaseModels: [CivitaiBaseModel] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.architectures = architectures
        self.sizeGrid = sizeGrid
        self.sizePresets = sizePresets
        self.defaultSize = defaultSize
        self.steps = steps
        self.stepsAreFixed = stepsAreFixed
        self.guidance = guidance
        self.supportsNegativePrompt = supportsNegativePrompt
        self.requiresTrait = requiresTrait
        self.loraFingerprints = loraFingerprints
        self.civitaiBaseModels = civitaiBaseModels
    }

    /// `true` when at least one LoRA fingerprint exists. A family without one accepts no LoRAs.
    public var acceptsLoRAs: Bool { !(loraFingerprints ?? []).isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, architectures, sizeGrid, sizePresets, defaultSize, steps
        case stepsAreFixed, guidance, supportsNegativePrompt, requiresTrait, loraFingerprints, civitaiBaseModels
    }

    /// `stepsAreFixed`, `requiresTrait` and `civitaiBaseModels` are optional in the JSON; absent means `false`,
    /// `nil` and `[]`, so records written before they existed decode unchanged.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            displayName: try container.decode(String.self, forKey: .displayName),
            architectures: try container.decode([String].self, forKey: .architectures),
            sizeGrid: try container.decode(SizeGrid.self, forKey: .sizeGrid),
            sizePresets: try container.decode([ImageSize].self, forKey: .sizePresets),
            defaultSize: try container.decode(ImageSize.self, forKey: .defaultSize),
            steps: try container.decode(StepsCapability.self, forKey: .steps),
            guidance: try container.decodeIfPresent(GuidanceCapability.self, forKey: .guidance),
            supportsNegativePrompt: try container.decode(Bool.self, forKey: .supportsNegativePrompt),
            stepsAreFixed: try container.decodeIfPresent(Bool.self, forKey: .stepsAreFixed) ?? false,
            requiresTrait: try container.decodeIfPresent(String.self, forKey: .requiresTrait),
            loraFingerprints: try container.decodeIfPresent([LoRAFingerprint].self, forKey: .loraFingerprints),
            civitaiBaseModels: try container.decodeIfPresent([CivitaiBaseModel].self, forKey: .civitaiBaseModels) ?? [])
    }
}

/// One name test for a LoRA tensor key (KTD4). Names are compared as exact prefixes, suffixes or substrings.
public struct TensorNamePattern: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case prefix, suffix, contains
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public func matches(_ name: String) -> Bool {
        switch kind {
        case .prefix: name.hasPrefix(text)
        case .suffix: name.hasSuffix(text)
        case .contains: name.contains(text)
        }
    }
}

/// A required tensor shape: some tensor whose name matches `pattern` must have `shape[dimension] == size`.
public struct LoRAShapeHint: Sendable, Codable, Hashable {
    public let pattern: TensorNamePattern
    public let dimension: Int
    public let size: Int

    public init(pattern: TensorNamePattern, dimension: Int, size: Int) {
        self.pattern = pattern
        self.dimension = dimension
        self.size = size
    }
}

/// A block family and the number of blocks the full model has, e.g. `double_blocks` with `5`. A LoRA may cover
/// only some of them (partial coverage is accepted), but every `family.N.` index found after the wrapper prefix
/// is stripped must be below `blockCount`, so a file that reaches a block the model lacks matches nothing.
public struct LoRABlockCount: Sendable, Codable, Hashable {
    /// Block-name prefix without the trailing dot, e.g. `double_blocks` or `transformer_blocks`.
    public let family: String
    /// The block count of the full model, taken from real sample headers.
    public let blockCount: Int

    public init(family: String, blockCount: Int) {
        self.family = family
        self.blockCount = blockCount
    }
}

/// The tensor keys, shapes and block counts one layout of a family's LoRAs must carry (KTD4).
/// Every entry is required. Names are matched after the wrapper prefix is stripped.
/// A fingerprint with no tensor patterns matches nothing, so an empty record never accepts a file.
public struct LoRAFingerprint: Sendable, Codable, Hashable {
    public let tensorPatterns: [TensorNamePattern]
    public let shapeHints: [LoRAShapeHint]
    public let blockCounts: [LoRABlockCount]
    /// The size variant (e.g. `4b`, `9b`) this layout belongs to, or `nil` when the layout names none (KTD6).
    public let variant: String?

    public init(
        tensorPatterns: [TensorNamePattern], shapeHints: [LoRAShapeHint] = [],
        blockCounts: [LoRABlockCount] = [], variant: String? = nil
    ) {
        self.tensorPatterns = tensorPatterns
        self.shapeHints = shapeHints
        self.blockCounts = blockCounts
        self.variant = variant
    }

    private enum CodingKeys: String, CodingKey {
        case tensorPatterns, shapeHints, blockCounts, variant
    }

    /// `shapeHints` and `blockCounts` are optional in the JSON; absent means none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tensorPatterns: try container.decode([TensorNamePattern].self, forKey: .tensorPatterns),
            shapeHints: try container.decodeIfPresent([LoRAShapeHint].self, forKey: .shapeHints) ?? [],
            blockCounts: try container.decodeIfPresent([LoRABlockCount].self, forKey: .blockCounts) ?? [],
            variant: try container.decodeIfPresent(String.self, forKey: .variant))
    }

    /// `tensors` maps each tensor name in a LoRA file to its shape.
    public func matches(tensors: [String: [Int]]) -> Bool {
        guard !tensorPatterns.isEmpty else { return false }
        let named = tensors.map { (name: loraNameWithoutWrapper($0.key), shape: $0.value) }
        let everyPatternFound = tensorPatterns.allSatisfy { pattern in
            named.contains { pattern.matches($0.name) }
        }
        guard everyPatternFound else { return false }
        let everyHintMet = shapeHints.allSatisfy { hint in
            named.contains { entry in
                hint.pattern.matches(entry.name) && entry.shape.indices.contains(hint.dimension)
                    && entry.shape[hint.dimension] == hint.size
            }
        }
        guard everyHintMet else { return false }
        let names = named.map { $0.name }
        return blockCounts.allSatisfy { requirement in
            guard let highest = highestBlockIndex(of: requirement.family, in: names) else { return false }
            return highest < requirement.blockCount
        }
    }
}

/// LoRA trainers prepend one of these wrapper prefixes to tensor names (PEFT, ComfyUI, diffusers).
private let loraWrapperPrefixes = ["base_model.model.", "diffusion_model.", "transformer."]

/// Strips the first wrapper prefix found, so one layout matches whichever trainer wrote the file.
private func loraNameWithoutWrapper(_ name: String) -> String {
    guard let prefix = loraWrapperPrefixes.first(where: { name.hasPrefix($0) }) else { return name }
    return String(name.dropFirst(prefix.count))
}

/// The highest `family.N.` block index in `names`, or `nil` if the family has no indexed tensor.
private func highestBlockIndex(of family: String, in names: [String]) -> Int? {
    let prefix = family + "."
    let indices = names.compactMap { name -> Int? in
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count).prefix { $0 != "." })
    }
    return indices.max()
}

/// The outcome of classifying one LoRA file against the families (KTD4).
public enum LoRAFamilyMatch: Sendable, Equatable {
    /// Exactly one family matches. `variant` is the size variant of its matching layouts, or `nil` when they name
    /// none or disagree.
    case family(String, variant: String?)
    /// No fingerprinted family matches. Lists the families that accept LoRAs, by display name.
    case unmatched(supportedFamilyNames: [String])
    /// Several families match, so none is chosen. Ids are in registry order.
    case ambiguous([String])
}

extension FamilyRegistry {
    /// Picks the family a LoRA belongs to from its tensor names and shapes. Families without a
    /// fingerprint never match and are not listed as supported.
    /// A file that two families both accept is `.ambiguous`: the classifier never guesses between them.
    public func classifyLoRA(tensors: [String: [Int]]) -> LoRAFamilyMatch {
        let fingerprinted = families.filter(\.acceptsLoRAs)
        let matched = fingerprinted.compactMap { family -> (id: String, variant: String?)? in
            let hits = (family.loraFingerprints ?? []).filter { $0.matches(tensors: tensors) }
            guard let first = hits.first else { return nil }
            let variants = Set(hits.map(\.variant))
            return (id: family.id, variant: variants.count == 1 ? first.variant : nil)
        }
        switch matched.count {
        case 0:
            return .unmatched(supportedFamilyNames: fingerprinted.map(\.displayName))
        case 1:
            return .family(matched[0].id, variant: matched[0].variant)
        default:
            return .ambiguous(matched.map(\.id))
        }
    }
}
