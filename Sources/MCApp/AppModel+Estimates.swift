import Foundation
import MCCatalog
import MCGeneration
import MCLibrary

/// Speed estimates for the model browser and the composer (KTD6, KTD7). All wording lives in `SpeedEstimate.label`.
extension AppModel {
    /// The estimate for `setup` on a model, or nil without an engine version, a baseline or a reference timing.
    func speedEstimate(modelID: String, reference: ReferenceTiming?, setup: TimingSetup) async -> SpeedEstimate? {
        guard let engineVersion, reference != nil else { return nil }
        let baseline = try? await store.baseline(engineVersion: engineVersion)
        return await speedEstimate(modelID: modelID, reference: reference, setup: setup, baseline: baseline)
    }

    private func speedEstimate(
        modelID: String, reference: ReferenceTiming?, setup: TimingSetup, baseline: CalibrationBaseline?
    ) async -> SpeedEstimate? {
        guard let engineVersion, let reference else { return nil }
        let key = TimingSampleKey(
            engineVersion: engineVersion, modelID: modelID, width: setup.width, height: setup.height,
            steps: setup.steps, loraCount: setup.loraCount)
        let recent = (try? await store.recentTimings(key: key)) ?? []
        return SpeedEstimator(engineVersion: engineVersion, baseline: baseline, reference: reference, recentSeconds: recent)
            .estimate(for: setup)
    }

    /// The reference timing of the catalog entry for an installed model.
    func referenceTiming(for modelID: String) -> ReferenceTiming? {
        browser.rows.first { $0.model?.repo == modelID }?.model?.referenceTiming
    }

    /// The time for one image at the composer's current size, steps and LoRA stack, or nil when none is known.
    func composerEstimate() async -> SpeedEstimate? {
        guard let model = selectedModel, ModelSelection.isSelectable(model), let family = model.family else { return nil }
        let user = loraStack.filter(\.isUsed).count
        let alwaysOn = ((try? await store.alwaysOnLoRAs(family: family.id)) ?? []).count
        let loraCount = min(user + alwaysOn, GenerationComposer.engineLoRAMax)
        let setup = TimingSetup(
            width: size.width, height: size.height,
            steps: family.stepsAreFixed ? family.steps.defaultSteps : (steps ?? family.steps.defaultSteps),
            loraCount: loraCount)
        return await speedEstimate(modelID: model.id, reference: referenceTiming(for: model.id), setup: setup)
    }

    /// Rebuilds the browser's per-model estimates and tells views to re-read the composer's. Overlapping calls
    /// coalesce into one more pass, so an older, slower pass never overwrites a newer result. Every call returns only
    /// after a pass that started after it has landed.
    func refreshEstimates() async {
        guard engineVersion != nil else { return }
        if let running = browser.estimatesRefresh {
            browser.estimatesRefreshPending = true
            await running.value
            return
        }
        let passes = Task { await self.runEstimatePasses() }
        browser.estimatesRefresh = passes
        await passes.value
    }

    /// Runs passes until no call asked for another. The slot clears in the same main-actor step as the last check, so
    /// a call that finds it set is always served by a later pass.
    private func runEstimatePasses() async {
        defer { browser.estimatesRefresh = nil }
        guard let engineVersion else { return }
        repeat {
            browser.estimatesRefreshPending = false
            let baseline = try? await store.baseline(engineVersion: engineVersion)
            let alwaysOn = (try? await store.alwaysOnLoRACounts()) ?? [:]
            var result: [String: SpeedEstimate] = [:]
            for row in browser.rows {
                guard let model = row.model, model.kind == .image, model.referenceTiming != nil,
                    let family = registry.families.first(where: { $0.id == model.family })
                else { continue }
                let setup = TimingSetup(
                    width: family.defaultSize.width, height: family.defaultSize.height, steps: family.steps.defaultSteps,
                    loraCount: min(alwaysOn[family.id] ?? 0, GenerationComposer.engineLoRAMax))
                if let estimate = await speedEstimate(
                    modelID: model.repo, reference: model.referenceTiming, setup: setup, baseline: baseline)
                {
                    result[model.repo] = estimate
                }
            }
            browser.estimates = result
            estimateRevision += 1
        } while browser.estimatesRefreshPending
    }
}
