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
    /// `nil` means the family ignores guidance and the control is hidden.
    public let guidance: GuidanceCapability?
    public let supportsNegativePrompt: Bool

    public init(
        id: String, displayName: String, architectures: [String], sizeGrid: SizeGrid,
        sizePresets: [ImageSize], defaultSize: ImageSize, steps: StepsCapability,
        guidance: GuidanceCapability?, supportsNegativePrompt: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.architectures = architectures
        self.sizeGrid = sizeGrid
        self.sizePresets = sizePresets
        self.defaultSize = defaultSize
        self.steps = steps
        self.guidance = guidance
        self.supportsNegativePrompt = supportsNegativePrompt
    }
}
