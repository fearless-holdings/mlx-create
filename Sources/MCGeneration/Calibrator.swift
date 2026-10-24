import Foundation
import MCCatalog
import MCEngine

/// The model one calibration run times, with the reference timing the catalog pins for it (KTD8).
public struct CalibrationTarget: Sendable, Equatable {
    public let modelID: String
    public let family: ModelFamily
    public let reference: ReferenceTiming

    public init(modelID: String, family: ModelFamily, reference: ReferenceTiming) {
        self.modelID = modelID
        self.family = family
        self.reference = reference
    }
}

/// One measured render: the size and steps it ran at, and the seconds from opening the generation stream to its
/// completed frame (KTD4). Model load is not in `seconds`.
public struct CalibrationMeasurement: Sendable, Equatable {
    public let modelID: String
    public let width: Int
    public let height: Int
    public let steps: Int
    public let seconds: Double

    public init(modelID: String, width: Int, height: Int, steps: Int, seconds: Double) {
        self.modelID = modelID
        self.width = width
        self.height = height
        self.steps = steps
        self.seconds = seconds
    }
}

/// Times what this Mac does at its best with one model (KTD3, KTD4). The caller owns the engine lane: the measurement
/// unloads every resident model, so it must not run while a generation or an enhancer lease uses the engine.
public enum Calibrator {
    /// The fixed benign prompt every calibration render uses.
    public static let prompt = "a calm lake at dawn, soft light on still water"
    /// The fixed seed every calibration render uses.
    public static let seed: UInt32 = 42
    /// Load attempts before an out-of-memory refusal is final: the first try and two retries (KTD3).
    static let loadAttempts = 3

    /// Empties the engine, loads `target`, renders twice and returns the second render. The first render absorbs
    /// first-run costs and is discarded. Errors propagate to the caller.
    public static func measure(
        client: EngineClient,
        target: CalibrationTarget,
        retryDelay: Duration = .seconds(30)
    ) async throws -> CalibrationMeasurement {
        try await emptyEngine(client: client, modelID: target.modelID, retryDelay: retryDelay)
        let request = calibrationRequest(for: target)
        _ = try await render(client: client, request: request, reference: target.reference)
        let second = try await render(client: client, request: request, reference: target.reference)
        return CalibrationMeasurement(
            modelID: target.modelID,
            width: request.width,
            height: request.height,
            steps: second.steps,
            seconds: second.seconds)
    }

    /// Unloads every resident model, then loads `modelID`. An out-of-memory refusal waits `retryDelay` and retries,
    /// up to ``loadAttempts`` tries in all. Never sends a preflight skip (KTD3).
    private static func emptyEngine(client: EngineClient, modelID: String, retryDelay: Duration) async throws {
        let resident = try await client.models().filter(\.loaded).map(\.id)
        for id in resident {
            try await client.unload(model: id)
        }
        var attempt = 1
        while true {
            do {
                try await client.load(model: modelID)
                return
            } catch EngineError.outOfMemory(engineMessage: _) where attempt < loadAttempts {
                attempt += 1
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    /// The calibration render: family default size, family default steps (none for fixed-step families), no guidance,
    /// no negative prompt, no LoRAs, the fixed prompt and seed.
    static func calibrationRequest(for target: CalibrationTarget) -> ImageRequest {
        let family = target.family
        return ImageRequest(
            model: target.modelID,
            prompt: prompt,
            width: family.defaultSize.width,
            height: family.defaultSize.height,
            steps: family.stepsAreFixed ? nil : family.steps.defaultSteps,
            guidance: nil,
            seed: seed)
    }

    private struct Render {
        let seconds: Double
        let steps: Int
    }

    /// Runs one generation and times it from before the stream opens to its completed frame. Steps come from the
    /// stream's own total, else the steps sent, else the reference steps.
    private static func render(client: EngineClient, request: ImageRequest, reference: ReferenceTiming) async throws -> Render {
        let clock = ContinuousClock()
        let start = clock.now
        var completedAt: ContinuousClock.Instant?
        var streamTotal: Int?
        for try await event in client.generateImage(request) {
            switch event {
            case .progress(_, let total, _):
                streamTotal = total
            case .completed:
                completedAt = clock.now
            }
        }
        guard let completedAt else { throw EngineError.streamEndedWithoutComplete }
        return Render(
            seconds: seconds(start.duration(to: completedAt)),
            steps: streamTotal ?? request.steps ?? reference.steps)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
