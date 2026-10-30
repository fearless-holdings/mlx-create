import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import Testing

/// The LoRA probes that need more than one file or a bare path (`docs/lld/engine-contract.md` §4: `lora.cap-eight-nine`
/// and `lora.relative-path-rejected`). The cap is `GenerationComposer.engineLoRAMax`, the number the executor and the
/// composer enforce, never a literal here.
@Suite(.serialized, .enabled(if: ContractEnvironment.enabled))
struct LoRACapContractTests {
    @Test func theLoRACapAndThePathRulesHold() async throws {
        try await ContractEngine.run { engine in
            let registry = try ContractModels.registry()
            let installed = try await engine.installedImageModels()
            let loras = try ContractLoRAs(registry: registry)
            try await probeCap(on: engine, registry: registry, installed: installed, loras: loras)
            try await probePaths(on: engine, registry: registry, installed: installed, loras: loras)
        }
    }

    /// `lora.cap-eight-nine`: eight LoRAs render and nine are refused, because the app's own cap is the engine's.
    private func probeCap(
        on engine: ContractEngine, registry: FamilyRegistry, installed: [InstalledModelRecord], loras: ContractLoRAs
    ) async throws {
        try await runProbe(ContractProbe.loraCapEightNine.rawValue, ledger: ContractRun.ledger) { check in
            let cap = GenerationComposer.engineLoRAMax
            let family = try loras.family(accepting: cap + 1, registry: registry)
            let model = try ContractModels.model(for: family, in: installed)
            try await ContractLoRARender.makeResident(model, on: engine)
            let atCap = try loras.files(for: family, requiring: cap)
            let png = try await ContractLoRARender.png(
                of: ContractLoRARender.request(
                    model: model.id, family: family, loraPaths: atCap.map(\.path), loraScales: atCap.map { _ in 1.0 }),
                on: engine)
            check.expect(ContractLoRARender.isPNG(png), "\(cap) LoRAs did not render a PNG")

            let overCap = try loras.files(for: family, requiring: cap + 1)
            let request = ContractLoRARender.request(
                model: model.id, family: family, loraPaths: overCap.map(\.path), loraScales: overCap.map { _ in 1.0 })
            let outcome = try await ContractLoRARender.attempt { try await ContractLoRARender.png(of: request, on: engine) }
            switch outcome {
            case .success:
                check.expect(false, "\(cap + 1) LoRAs were accepted, though the engine caps a request at \(cap)")
            case .failure(let error):
                // The app never sends more than `engineLoRAMax` (the composer and executor stop it first), so the
                // engine's own 400 is the backstop. It names the field and the cap, and is not a `no modules matching`.
                if case EngineError.badRequest(let message) = error {
                    check.expect(
                        message?.contains("max \(cap)") == true,
                        "the over-cap rejection does not name the cap of \(cap): \(message ?? "no engine message")")
                } else {
                    check.expect(false, "\(cap + 1) LoRAs must fail as the engine's 400; the client raised \(error)")
                }
            }
        }
    }

    /// `lora.relative-path-rejected`: the app always sends absolute library paths. An absolute path outside the
    /// engine's model directory loads; a relative one does not.
    private func probePaths(
        on engine: ContractEngine, registry: FamilyRegistry, installed: [InstalledModelRecord], loras: ContractLoRAs
    ) async throws {
        try await runProbe(ContractProbe.loraRelativePathRejected.rawValue, ledger: ContractRun.ledger) { check in
            let (family, user) = try loras.firstFamilyWithAUserFile(in: registry)
            let model = try ContractModels.model(for: family, in: installed)
            try await ContractLoRARender.makeResident(model, on: engine)
            let absolute = try await ContractLoRARender.png(
                of: ContractLoRARender.request(
                    model: model.id, family: family, loraPaths: [user.path], loraScales: [1]),
                on: engine)
            check.expect(
                ContractLoRARender.isPNG(absolute),
                "an absolute path outside the engine's model directory did not load: \(user.path)")

            let relative = "LoRAs/\(family.id)/\(user.fileName)"
            let request = ContractLoRARender.request(
                model: model.id, family: family, loraPaths: [relative], loraScales: [1])
            let outcome = try await ContractLoRARender.attempt { try await ContractLoRARender.png(of: request, on: engine) }
            switch outcome {
            case .success:
                check.expect(false, "the engine accepted the relative LoRA path \(relative)")
            case .failure(let error):
                guard let engineError = error as? EngineError else {
                    check.expect(false, "the relative LoRA path did not reach the engine: \(error)")
                    return
                }
                switch engineError {
                case .connectionLost, .timedOut, .streamEndedWithoutComplete:
                    check.expect(false, "the engine never answered the relative path \(relative): \(engineError)")
                default:
                    break
                }
            }
        }
    }
}
