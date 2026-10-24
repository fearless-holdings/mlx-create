import Foundation
import MCCatalog
import MCGeneration
import MCLibrary

/// Speed estimates for the model browser and the composer (KTD6, KTD7). All wording lives in `SpeedEstimate.label`.
extension AppModel {
    /// The estimate for `setup` on a model, or nil without an engine version, a baseline or a reference timing.
    func speedEstimate(modelID: String, reference: ReferenceTiming?, setup: TimingSetup) async -> SpeedEstimate? {
        guard let engineVersion, let reference else { return nil }
        let baseline = try? await store.baseline(engineVersion: engineVersion)
        let key = TimingSampleKey(
            engineVersion: engineVersion, modelID: modelID, width: setup.width, height: setup.height,
            steps: setup.steps, loraCount: setup.loraCount)
        let recent = (try? await store.recentTimings(key: key)) ?? []
        return SpeedEstimator(engineVersion: engineVersion, baseline: baseline, reference: reference, recentSeconds: recent)
            .estimate(for: setup)
    }

    /// The reference timing of the catalog entry for an installed model.
    private func referenceTiming(for modelID: String) -> ReferenceTiming? {
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

    /// Rebuilds the browser's per-model estimates and tells views to re-read the composer's.
    func refreshEstimates() async {
        guard engineVersion != nil else { return }
        var result: [String: SpeedEstimate] = [:]
        for row in browser.rows {
            guard let model = row.model, model.kind == .image, model.referenceTiming != nil,
                let family = registry.families.first(where: { $0.id == model.family })
            else { continue }
            let setup = TimingSetup(
                width: family.defaultSize.width, height: family.defaultSize.height, steps: family.steps.defaultSteps, loraCount: 0)
            if let estimate = await speedEstimate(modelID: model.repo, reference: model.referenceTiming, setup: setup) {
                result[model.repo] = estimate
            }
        }
        browser.estimates = result
        estimateRevision += 1
    }
}
