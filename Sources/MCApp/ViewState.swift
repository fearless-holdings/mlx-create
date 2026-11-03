import Foundation
import MCCatalog
import MCLibrary

/// One-line engine status above the canvas (U8 step 7). `nil` banner means the engine is ready and idle.
public enum EngineBanner: Equatable, Sendable {
    case starting
    case warmingModel(String)
    case restarting
    case failed(String)
}

/// A model the engine found but the app cannot drive, with the reason shown in the picker (R9).
public struct UnavailableModelRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let reason: String

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }
}

/// What the canvas shows (U8 step 6).
public enum CanvasMode: Equatable, Sendable {
    /// Zero installed image models: offer Browse models (R10).
    case noModels
    /// Image models exist but none can be driven: list each with its reason, no Reveal action.
    case onlyUnavailable([UnavailableModelRow])
    /// A model is available but nothing has been generated: show the hint that matches whether a prompt is typed.
    case emptyHint
    /// Show the selected image or the running generation's step bar.
    case content
}

/// The settings controls the selected model's family allows (R7). `nil` members mean the control is hidden.
public struct SettingsControls: Equatable, Sendable {
    public var sizes: [ImageSize]
    public var steps: StepsCapability
    /// True when the family fixes the step count; the generation panel shows it read-only.
    public var stepsAreFixed: Bool
    public var guidance: GuidanceCapability?
    public var showsNegativePrompt: Bool

    public init(
        sizes: [ImageSize], steps: StepsCapability, stepsAreFixed: Bool,
        guidance: GuidanceCapability?, showsNegativePrompt: Bool
    ) {
        self.sizes = sizes
        self.steps = steps
        self.stepsAreFixed = stepsAreFixed
        self.guidance = guidance
        self.showsNegativePrompt = showsNegativePrompt
    }
}

/// A job in the queue strip, with the actions its context menu offers.
public struct JobItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var status: JobStatus
    public var promptSnippet: String
    public var savedCount: Int
    public var batchCount: Int
    /// Current engine step for the running job; nil otherwise.
    public var step: Int?
    public var total: Int?
    public var failure: JobFailure?
    public var canMoveUp: Bool
    public var canMoveDown: Bool
    public var canCancel: Bool
    public var canRetry: Bool
    /// The LoRAs the job carries, as frozen when it was queued.
    public var loraIDs: [String]
    public var loraNames: [String]

    public init(
        id: UUID, status: JobStatus, promptSnippet: String, savedCount: Int, batchCount: Int,
        step: Int? = nil, total: Int? = nil, failure: JobFailure? = nil,
        canMoveUp: Bool = false, canMoveDown: Bool = false, canCancel: Bool = false, canRetry: Bool = false,
        loraIDs: [String] = [], loraNames: [String] = []
    ) {
        self.id = id
        self.status = status
        self.promptSnippet = promptSnippet
        self.savedCount = savedCount
        self.batchCount = batchCount
        self.step = step
        self.total = total
        self.failure = failure
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.canCancel = canCancel
        self.canRetry = canRetry
        self.loraIDs = loraIDs
        self.loraNames = loraNames
    }

    /// A failed or cancelled job: its cell can be removed from the strip, and Clear removes it with the others.
    public var isDismissible: Bool { status == .failed || status == .cancelled }
}

/// Queue header state (U8 step 4). `calibrating` is the on-device speed measurement (R8): no Pause or Resume, and no job runs.
public enum QueueHeader: Equatable, Sendable {
    case idle
    case running
    case pausing
    case paused
    case calibrating

    /// Only a running queue offers Pause; a pausing or calibrating header never does.
    public var offersPause: Bool { self == .running }

    /// Only a paused queue offers Resume.
    public var offersResume: Bool { self == .paused }
}
