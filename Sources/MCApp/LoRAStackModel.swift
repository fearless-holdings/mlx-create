import Foundation
import MCCatalog

/// One row of the generation panel's LoRA stack, derived from the stack state, the library and the selected model (R9-R13).
public struct LoRAStackRow: Identifiable, Equatable, Sendable {
    /// The `lora` table id, so one row per LoRA.
    public var id: String
    public var name: String
    public var sha256: String
    public var familyID: String
    /// The LoRA's family display name, e.g. "FLUX.2 klein".
    public var familyName: String
    public var weight: Double
    public var isEnabled: Bool
    /// Whether this row's slider spans the engine's -20...20 instead of -2...2.
    public var wideRange: Bool
    public var triggerWords: [String]
    public var fit: LoRAFit
    /// An enabled LoRA with trigger words, none of which the prompt contains.
    public var missingTriggerHint: Bool
    /// Enabled, fitting and at a non-zero weight: the row goes into the next job.
    public var isUsed: Bool

    public init(
        id: String, name: String, sha256: String, familyID: String, familyName: String, weight: Double,
        isEnabled: Bool, wideRange: Bool, triggerWords: [String], fit: LoRAFit, missingTriggerHint: Bool, isUsed: Bool
    ) {
        self.id = id
        self.name = name
        self.sha256 = sha256
        self.familyID = familyID
        self.familyName = familyName
        self.weight = weight
        self.isEnabled = isEnabled
        self.wideRange = wideRange
        self.triggerWords = triggerWords
        self.fit = fit
        self.missingTriggerHint = missingTriggerHint
        self.isUsed = isUsed
    }
}

/// Whether a LoRA can be used with the selected model.
public enum LoRAFit: Equatable, Sendable {
    /// The LoRA's family is the selected model's family.
    case fits
    /// The selected model is from another family; `selectedModelName` is its display name.
    case doesNotFit(selectedModelName: String)
    /// The LoRA's family has no installed model, so the user must install one first.
    case needsModelInstalled(familyName: String)
    /// The selected model's family accepts no LoRAs at all.
    case modelTakesNoLoRAs
    /// The LoRA's file is gone from the library folder. No model switch makes it usable, so this outranks the fit (R17).
    case fileMissing

    /// The plain reason a greyed row shows, or nil when the LoRA fits.
    public var reason: String? {
        switch self {
        case .fits: nil
        case .doesNotFit(let name): "doesn't fit \(name)"
        case .needsModelInstalled(let familyName): "needs \(familyName) installed"
        case .modelTakesNoLoRAs: "this model takes no LoRAs"
        case .fileMissing: "file missing from the LoRA library: re-import or remove it"
        }
    }
}

/// One LoRA in the library, as the library sheet lists it.
public struct LoRALibraryItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var familyName: String
    public var familyID: String
    public var sizeBytes: Int64
    public var triggerWords: [String]
    public var notes: String?
    /// The file is gone from disk, so the LoRA cannot be used until it is re-imported or deleted.
    public var fileMissing: Bool
    /// The LoRA fits the selected model.
    public var fitsSelectedModel: Bool
    public var inStack: Bool

    public init(
        id: String, name: String, familyName: String, familyID: String, sizeBytes: Int64, triggerWords: [String],
        notes: String?, fileMissing: Bool, fitsSelectedModel: Bool, inStack: Bool
    ) {
        self.id = id
        self.name = name
        self.familyName = familyName
        self.familyID = familyID
        self.sizeBytes = sizeBytes
        self.triggerWords = triggerWords
        self.notes = notes
        self.fileMissing = fileMissing
        self.fitsSelectedModel = fitsSelectedModel
        self.inStack = inStack
    }
}

/// Progress of a multi-file import: the file being copied, its position, and its own copy fraction.
public struct LoRAImportProgress: Equatable, Sendable {
    public var currentFile: String
    /// One-based position of `currentFile` in the import.
    public var index: Int
    public var total: Int
    public var fraction: Double

    public init(currentFile: String, index: Int, total: Int, fraction: Double) {
        self.currentFile = currentFile
        self.index = index
        self.total = total
        self.fraction = fraction
    }
}

/// A file an import did not add, with the plain reason it was refused.
public struct LoRARefusal: Equatable, Sendable {
    public var file: String
    public var reason: String

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

/// What a multi-file import did: names added, names already installed, and files refused.
public struct LoRAImportSummary: Equatable, Sendable {
    public var added: [String] = []
    /// Names of the installed LoRAs that a file duplicated. Those LoRAs are unchanged.
    public var duplicates: [String] = []
    public var refused: [LoRARefusal] = []

    public init(added: [String] = [], duplicates: [String] = [], refused: [LoRARefusal] = []) {
        self.added = added
        self.duplicates = duplicates
        self.refused = refused
    }
}

/// The outcome of deleting a LoRA from the library.
public enum LoRADeleteResult: Equatable, Sendable {
    /// The LoRA and its file are gone. `imagesUsingIt` saved images still name it in their settings.
    case deleted(imagesUsingIt: Int)
    /// A queued, running, paused or retryable job uses the LoRA, so nothing was deleted.
    case refused(message: String)
    case failed(message: String)
}

/// One LoRA in the stack, in stack order. This is the only stored stack state: rows are derived from it.
struct LoRAStackSlot: Equatable, Sendable {
    let id: String
    var weight: Double
    var isEnabled: Bool
    var wideRange: Bool
}

extension LoRAStackSlot {
    /// An enabled slot at `weight`, on the wide range when the weight needs it, so a restored or shelf weight is never lost.
    init(id: String, requestedWeight weight: Double) {
        let wide = abs(weight) > LoRAStackRules.narrowRange.upperBound
        self.init(id: id, weight: LoRAStackRules.clamped(weight, wide: wide), isEnabled: true, wideRange: wide)
    }
}

/// Pure rules for the LoRA stack: weight ranges and fit (R10-R12). Trigger-word matching lives in `TriggerWordMatcher`.
enum LoRAStackRules {
    static let narrowRange: ClosedRange<Double> = -2...2
    static let wideRange: ClosedRange<Double> = -20...20

    static func range(wide: Bool) -> ClosedRange<Double> {
        wide ? wideRange : narrowRange
    }

    static func clamped(_ weight: Double, wide: Bool) -> Double {
        let bounds = range(wide: wide)
        return min(max(weight, bounds.lowerBound), bounds.upperBound)
    }

    /// The fit of a LoRA of `loraFamilyID` against the selected model's family. `selected` is nil when no selectable
    /// model is chosen, and a family that accepts no LoRAs gives `modelTakesNoLoRAs`.
    static func fit(
        loraFamilyID: String, loraFamilyName: String, selected: ModelFamily?, installedFamilyIDs: Set<String>
    ) -> LoRAFit {
        guard let selected else {
            if !installedFamilyIDs.contains(loraFamilyID) {
                return .needsModelInstalled(familyName: loraFamilyName)
            }
            return .doesNotFit(selectedModelName: "the selected model")
        }
        guard selected.acceptsLoRAs else { return .modelTakesNoLoRAs }
        if selected.id == loraFamilyID {
            return .fits
        }
        if !installedFamilyIDs.contains(loraFamilyID) {
            return .needsModelInstalled(familyName: loraFamilyName)
        }
        return .doesNotFit(selectedModelName: selected.displayName)
    }

    /// Whether a LoRA of `loraVariant` fits a model of `modelVariant` (KTD6): a size named on both sides that differs
    /// does not fit, and a missing variant never gates. `fit` gates on family; callers that know a variant gate on
    /// this too (Civitai attach, the agent's model keys).
    static func variantFits(loraVariant: String?, modelVariant: String?) -> Bool {
        loraVariant == nil || modelVariant == nil || loraVariant == modelVariant
    }
}
