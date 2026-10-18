import Foundation
import MCCatalog
import MCGeneration

/// Pure rules for choosing a model and fitting the composer to its family (R7, R9, R10).
enum ModelSelection {
    /// A model the app can drive: the engine reports it, a verified family covers it, and it is not unavailable.
    static func isSelectable(_ model: InstalledModel) -> Bool {
        guard case .available = model.availability else { return false }
        return model.family != nil
    }

    /// The first selectable model in registry order, which is the launch default when the last-used model is gone.
    static func defaultModelID(in models: [InstalledModel], registry: FamilyRegistry) -> String? {
        let selectable = models.filter(isSelectable)
        for family in registry.families {
            if let model = selectable.first(where: { $0.family?.id == family.id }) {
                return model.id
            }
        }
        return nil
    }

    /// The controls a family allows. `nil` when no selectable model is chosen.
    static func controls(for model: InstalledModel?) -> SettingsControls? {
        guard let model, isSelectable(model), let family = model.family else { return nil }
        return SettingsControls(
            sizes: family.sizePresets,
            steps: family.steps,
            stepsAreFixed: family.stepsAreFixed,
            guidance: family.guidance,
            showsNegativePrompt: family.supportsNegativePrompt)
    }

    static func unavailableRows(_ models: [InstalledModel]) -> [UnavailableModelRow] {
        models.compactMap { model -> UnavailableModelRow? in
            guard case .unavailable(let reason) = model.availability else { return nil }
            return UnavailableModelRow(id: model.id, reason: reason)
        }
    }

    /// Brings composer values into the family's allowed ranges. A size outside the presets becomes the family
    /// default; steps are cleared when the family fixes them or they fall outside its range; guidance is cleared when the family has none (R7).
    static func fit(
        size: ImageSize, steps: Int?, guidance: Double?, to family: ModelFamily
    ) -> (size: ImageSize, steps: Int?, guidance: Double?) {
        let fittedSize = family.sizePresets.contains(size) ? size : family.defaultSize
        let fittedSteps = family.stepsAreFixed ? nil : steps.flatMap { (family.steps.min...family.steps.max).contains($0) ? $0 : nil }
        let fittedGuidance: Double?
        if let capability = family.guidance, let value = guidance, (capability.min...capability.max).contains(value) {
            fittedGuidance = value
        } else {
            fittedGuidance = nil
        }
        return (fittedSize, fittedSteps, fittedGuidance)
    }
}
