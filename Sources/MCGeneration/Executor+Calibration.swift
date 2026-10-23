import Foundation
import MCLibrary
import OSLog

/// On-device calibration inside the executor's drain (KTD1, KTD2, KTD8, KTD11). A calibration runs only when the queue has
/// no job to claim, one run per engine version, and it creates no job, image or prompt-history row.
extension JobExecutor {
    private static let calibrationLog = Logger(subsystem: "app.mlx-create", category: "calibration")

    /// The calibration this launch should run now, or nil when none is due: no engine version, no target, this launch
    /// already tried, or the version already has a baseline.
    private func dueCalibration() async throws -> (version: String, target: CalibrationTarget)? {
        guard !calibrationTriedThisLaunch, let engineVersion else { return nil }
        guard let target = await calibrationTargets().first else { return nil }
        guard try await store.baseline(engineVersion: engineVersion) == nil else { return nil }
        return (engineVersion, target)
    }

    /// Runs the due calibration when the queue has no job. Returns true when the drain should look at the queue again:
    /// a calibration ran, or a lease or job started while the queue read was suspended. Returns false when nothing is due.
    func calibrateIfDue() async throws -> Bool {
        guard let due = try await dueCalibration() else { return false }
        // Re-checked in the same synchronous segment that starts the run, so a lease that began during the queue read
        // waits for the next pass instead of sharing the engine with this calibration.
        guard !enhancerLeaseHeld, currentJobID == nil else { return true }
        calibrationTriedThisLaunch = true
        hub.send(.calibrationChanged(true))
        defer { hub.send(.calibrationChanged(false)) }
        let engine = self.client
        let library = self.store
        let retryDelay = calibrationRetryDelay
        let (version, target) = due
        do {
            // Serialized with model switches, so a job or lease that follows waits for the calibration to finish.
            try await serialized {
                let measurement = try await Calibrator.measure(client: engine, target: target, retryDelay: retryDelay)
                try await library.saveBaseline(
                    CalibrationBaseline(
                        engineVersion: version, modelID: measurement.modelID, width: measurement.width,
                        height: measurement.height, steps: measurement.steps, seconds: measurement.seconds,
                        referenceSeconds: target.reference.seconds, measuredAt: Date()))
            }
        } catch {
            if error is CancellationError { throw error }
            // A failed calibration stores nothing and fails no job. It is not retried until the next launch (AE7).
            Self.calibrationLog.error("Calibration did not finish: \(String(describing: error))")
        }
        return true
    }

    /// Starts the drain when a calibration is due. Called when an Enhance lease releases, so a calibration that waited
    /// behind the lease is not left until the next queue event.
    func kickIfCalibrationDue() async {
        do {
            if try await dueCalibration() != nil { start() }
        } catch {
            Self.calibrationLog.error("Calibration check failed: \(String(describing: error))")
        }
    }
}
