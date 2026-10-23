import Foundation
import MCCatalog
import MCGeneration

/// The calibration targets the drain reads (KTD9). The executor is built before `AppModel` finishes its init, so it
/// holds this source, and `AppModel` attaches itself at the end of init.
@MainActor
final class CalibrationTargetSource {
    weak var model: AppModel?

    func targets() -> [CalibrationTarget] {
        model?.calibrationTargets() ?? []
    }
}

extension AppModel {
    /// The installed image models that have a reference timing, the selected model first, then registry order. Empty
    /// unless the engine is ready, so no calibration starts while the engine is down, starting or restarting.
    func calibrationTargets() -> [CalibrationTarget] {
        guard case .ready = engineState else { return [] }
        let installed = models.filter(ModelSelection.isSelectable)
        let selected = installed.filter { $0.id == selectedModelID }
        let others = registry.families.flatMap { family in
            installed.filter { $0.family?.id == family.id && $0.id != selectedModelID }
        }
        return (selected + others).compactMap { model -> CalibrationTarget? in
            guard let family = model.family,
                let reference = browser.rows.first(where: { $0.model?.repo == model.id })?.model?.referenceTiming
            else { return nil }
            return CalibrationTarget(modelID: model.id, family: family, reference: reference)
        }
    }
}
