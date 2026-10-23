import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import Testing

private let measurementEnvironment = ProcessInfo.processInfo.environment

/// Measurement harness for catalog `reference_timing` values (KTD8). Runs only when MLXC_ENGINE_BIN points at the
/// pinned engine executable and MLXC_MEASURE_MODEL_DIR names a directory of model folders, the engine's `--model-dir`.
/// MLXC_MEASURE_MODEL_ID selects the model to time. Prints one `REFERENCE_TIMING` line; asserts nothing about the number.
@Suite(
    .enabled(
        if: measurementEnvironment["MLXC_ENGINE_BIN"] != nil && measurementEnvironment["MLXC_MEASURE_MODEL_DIR"] != nil))
struct ReferenceTimingMeasurementTests {
    @Test func printsReferenceTimingForOneModelOnTheRealEngine() async throws {
        let binary = try #require(measurementEnvironment["MLXC_ENGINE_BIN"])
        let modelDir = URL(fileURLWithPath: try #require(measurementEnvironment["MLXC_MEASURE_MODEL_DIR"]), isDirectory: true)
        let modelID = try #require(measurementEnvironment["MLXC_MEASURE_MODEL_ID"])

        // Isolated app support and HOME: the engine never sees ~/.mlx-serve. The engine's Weights folder is a
        // symlink to the user's model directory, so nothing in that directory is moved or written.
        let root = FileManager.default.temporaryDirectory.appending(path: "mlxc-measure-\(UUID().uuidString)")
        let models = root.appending(path: "Models", directoryHint: .isDirectory)
        let weights = models.appending(path: "Weights", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: weights, withDestinationURL: modelDir)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = EnginePaths(
            executable: URL(fileURLWithPath: binary),
            appSupport: root.appending(path: "AppSupport", directoryHint: .isDirectory),
            modelsRoot: { models })
        let tier = MemoryTier(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        let supervisor = EngineSupervisor(paths: paths, tier: tier)

        let measurement: CalibrationMeasurement
        do {
            measurement = try await measure(supervisor: supervisor, modelID: modelID, weights: weights)
        } catch {
            await supervisor.stop()
            throw error
        }
        await supervisor.stop()

        let seconds = (measurement.seconds * 100).rounded() / 100
        print(
            "REFERENCE_TIMING model=\(measurement.modelID) width=\(measurement.width) height=\(measurement.height) "
                + "steps=\(measurement.steps) seconds=\(seconds)")
    }

    /// Starts the engine, waits for `.ready`, resolves the model's family from the engine's own report, and runs one
    /// calibration measurement. The caller stops the supervisor whether this returns or throws.
    private func measure(
        supervisor: EngineSupervisor, modelID: String, weights: URL
    ) async throws -> CalibrationMeasurement {
        await supervisor.start()
        try await waitForReady(supervisor)
        let client = EngineClient(endpoint: {
            guard let current = await supervisor.endpoint else { throw CancellationError() }
            return current
        })

        let registry = try FamilyRegistry.bundled()
        let installed = try await InstalledModels(registry: registry, weightsRoot: weights).refresh(using: client)
        let model = try #require(installed.first(where: { $0.id == modelID }), "the engine does not list \(modelID)")
        let family = try #require(model.family, "no verified family covers \(modelID)")

        // Only the family's default size and steps reach the render (Calibrator.calibrationRequest); the placeholder
        // reference is never read for the number.
        let target = CalibrationTarget(
            modelID: modelID,
            family: family,
            reference: ReferenceTiming(
                width: family.defaultSize.width, height: family.defaultSize.height, steps: 1, seconds: 1))
        return try await Calibrator.measure(client: client, target: target)
    }

    /// Resolves once the supervisor reports `.ready`; a `.failed` state throws its crash.
    private func waitForReady(_ supervisor: EngineSupervisor) async throws {
        for await state in await supervisor.states {
            switch state {
            case .ready: return
            case .failed(let crash): throw crash
            case .stopped, .starting, .restarting: continue
            }
        }
        throw CancellationError()
    }
}
