import Foundation
import MCCatalog
import MCEngine
import Testing

@testable import MCEngine

/// The per-family LoRA contract of `docs/lld/engine-contract.md` §4 (R3). Every size, step count and capability comes
/// from the family record, every file from its safetensors header, and every byte comparison stays inside this one
/// engine run (KTD4): no golden image from another engine version.
@Suite(.serialized, .enabled(if: ContractEnvironment.enabled))
struct LoRAContractTests {
    @Test func theLoRAProbesHoldForEveryFamilyThatAcceptsLoRAs() async throws {
        try await ContractEngine.run { engine in
            let registry = try ContractModels.registry()
            let installed = try await engine.installedImageModels()
            let loras = try ContractLoRAs(registry: registry)
            let baselines = ContractLoRABaseline()
            for family in registry.families where family.acceptsLoRAs {
                try await probeFamily(family, on: engine, installed: installed, loras: loras, baselines: baselines)
            }
            try await probeAlwaysOn(on: engine, registry: registry, installed: installed, loras: loras, baselines: baselines)
            try await probeNoRescan(on: engine, registry: registry, installed: installed, loras: loras, baselines: baselines)
        }
    }

    /// `lora.applies`, `lora.scale-zero`, `lora.scale-range` and `lora.rejects-wrong-family` for one family, on the
    /// family's model, at its smallest preset and with one fixed seed. The model is made resident inside each probe, so
    /// a memory refusal stays inconclusive for the run (KTD7) instead of escaping the ledger.
    private func probeFamily(
        _ family: ModelFamily, on engine: ContractEngine, installed: [InstalledModelRecord], loras: ContractLoRAs,
        baselines: ContractLoRABaseline
    ) async throws {
        let model = try ContractModels.model(for: family, in: installed)
        let bare = ContractLoRARender.request(model: model.id, family: family)

        try await runProbe(FamilyProbe.loraApplies.id(for: family), ledger: ContractRun.ledger) { check in
            let user = try loras.first(for: family)
            try await ContractLoRARender.makeResident(model, on: engine)
            let withoutLoRA = try await baselines.png(for: family.id, request: bare, on: engine)
            let withLoRA = try await ContractLoRARender.png(
                of: ContractLoRARender.request(
                    model: model.id, family: family, loraPaths: [user.path], loraScales: [1]),
                on: engine)
            check.expect(ContractLoRARender.isPNG(withLoRA), "the render with \(user.fileName) is not a PNG")
            check.expect(withLoRA != withoutLoRA, "\(user.fileName) at scale 1 returned the bytes of the render without it")
        }

        try await runProbe(FamilyProbe.loraScaleZero.id(for: family), ledger: ContractRun.ledger) { check in
            let user = try loras.first(for: family)
            try await ContractLoRARender.makeResident(model, on: engine)
            let withoutLoRA = try await baselines.png(for: family.id, request: bare, on: engine)
            let scaleZero = try await ContractLoRARender.png(
                of: ContractLoRARender.request(
                    model: model.id, family: family, loraPaths: [user.path], loraScales: [0]),
                on: engine)
            check.expect(ContractLoRARender.isPNG(scaleZero), "the render with \(user.fileName) at scale 0 is not a PNG")
            check.expect(
                scaleZero == withoutLoRA,
                "\(user.fileName) at scale 0 changed the bytes: strength 0 must turn a LoRA off (docs/lld/engine.md §5.10)")
        }

        try await runProbe(FamilyProbe.loraScaleRange.id(for: family), ledger: ContractRun.ledger) { check in
            let user = try loras.first(for: family)
            try await ContractLoRARender.makeResident(model, on: engine)
            for scale in [-1.0, 5.0] {
                let png = try await ContractLoRARender.png(
                    of: ContractLoRARender.request(
                        model: model.id, family: family, loraPaths: [user.path], loraScales: [scale]),
                    on: engine)
                check.expect(ContractLoRARender.isPNG(png), "scale \(scale) on \(user.fileName) did not return a PNG")
            }
        }

        try await runProbe(FamilyProbe.loraRejectsWrongFamily.id(for: family), ledger: ContractRun.ledger) { check in
            let other = try loras.fileFromAnotherFamily(than: family)
            try await ContractLoRARender.makeResident(model, on: engine)
            let request = ContractLoRARender.request(
                model: model.id, family: family, loraPaths: [other.path], loraScales: [1])
            let outcome = try await ContractLoRARender.attempt { try await ContractLoRARender.png(of: request, on: engine) }
            switch outcome {
            case .success:
                check.expect(false, "the engine accepted \(other.family)'s \(other.fileName) on \(family.id)")
            case .failure(let error):
                if case EngineError.loraRejected(let message) = error {
                    check.expect(
                        message?.contains("no modules matching") == true,
                        "the rejection lacks 'no modules matching': \(message ?? "no engine message")")
                } else {
                    check.expect(false, "a wrong-family LoRA must map to loraRejected; the client raised \(error)")
                }
            }
            let captured = try await captureWrongFamily(family, request: request, on: engine)
            check.expect(captured.status == 400, "a wrong-family LoRA must be HTTP 400; got \(captured.status)")
            check.expect(
                captured.body.contains("no modules matching"),
                "the 400 body lacks 'no modules matching': \(captured.body.prefix(300))")
            switch captured.mapped {
            case .loraRejected: break
            default: check.expect(false, "the app maps this response to \(captured.mapped) instead of loraRejected")
            }
            check.expect(captured.saved, "the verbatim 400 body of the wrong-family probe was not saved")
        }
    }

    /// The raw response a wrong-family request gets, the error the app maps it to, and whether its verbatim body was
    /// saved under `NSTemporaryDirectory()/mlxc-contract-captures/<engine version>/`.
    private struct WrongFamilyCapture {
        let status: Int
        let body: String
        let mapped: EngineError
        let saved: Bool
    }

    /// Sends the same body raw, because the client keeps only the envelope's message and the probe records the
    /// verbatim 400 body. The app's own mapping (`EngineError.fromResponse`: 400 plus `no modules matching` is
    /// `loraRejected`) runs against that captured body.
    private func captureWrongFamily(
        _ family: ModelFamily, request: ImageRequest, on engine: ContractEngine
    ) async throws -> WrongFamilyCapture {
        let object = try JSONSerialization.jsonObject(with: request.body())
        let raw = try await RawHTTP.send(
            "POST", "v1/images/generations", to: engine.endpoint, key: engine.endpoint.apiKey, json: object)
        let version = ContractRun.ledger.engineVersion
        let url = try ContractLoRACapture.save(
            raw.body, named: "\(FamilyProbe.loraRejectsWrongFamily.rawValue).\(family.id).http\(raw.status).txt",
            engineVersion: version)
        return WrongFamilyCapture(
            status: raw.status, body: raw.text,
            mapped: EngineError.fromResponse(status: raw.status, body: raw.body),
            saved: FileManager.default.fileExists(atPath: url.path))
    }

    /// `lora.always-on-plus-user`: the family's always-on file after one user LoRA, the order the executor appends them
    /// in (D44), still renders.
    private func probeAlwaysOn(
        on engine: ContractEngine, registry: FamilyRegistry, installed: [InstalledModelRecord], loras: ContractLoRAs,
        baselines: ContractLoRABaseline
    ) async throws {
        try await runProbe(ContractProbe.loraAlwaysOnPlusUser.rawValue, ledger: ContractRun.ledger) { check in
            let alwaysOn = try loras.alwaysOn()
            let family = try ContractLoRARender.family(alwaysOn.family, in: registry)
            let model = try ContractModels.model(for: family, in: installed)
            let user = try loras.first(for: family)
            try await ContractLoRARender.makeResident(model, on: engine)
            let bare = ContractLoRARender.request(model: model.id, family: family)
            let withoutLoRAs = try await baselines.png(for: family.id, request: bare, on: engine)
            let combined = ContractLoRARender.request(
                model: model.id, family: family, loraPaths: [user.path, alwaysOn.file.path],
                loraScales: [1, alwaysOn.scale])
            let png = try await ContractLoRARender.png(of: combined, on: engine)
            check.expect(ContractLoRARender.isPNG(png), "the always-on plus user LoRA render is not a PNG")
            check.expect(png != withoutLoRAs, "the always-on file with \(user.fileName) left the render unchanged")
        }
    }

    /// `lora.no-rescan-needed`: a file that appears after launch applies without a rescan. Nothing is written into the
    /// LoRA directory: the file is linked into the run's throwaway root, a path the engine never saw at launch.
    private func probeNoRescan(
        on engine: ContractEngine, registry: FamilyRegistry, installed: [InstalledModelRecord], loras: ContractLoRAs,
        baselines: ContractLoRABaseline
    ) async throws {
        try await runProbe(ContractProbe.loraNoRescanNeeded.rawValue, ledger: ContractRun.ledger) { check in
            let (family, user) = try loras.firstFamilyWithAUserFile(in: registry)
            let model = try ContractModels.model(for: family, in: installed)
            try await ContractLoRARender.makeResident(model, on: engine)
            let bare = ContractLoRARender.request(model: model.id, family: family)
            let withoutLoRA = try await baselines.png(for: family.id, request: bare, on: engine)
            let placed = try ContractLoRARender.placedAfterLaunch(user, in: engine.root)
            check.expect(
                placed.path != user.path, "\(placed.lastPathComponent) reused the library path a launch would have seen")
            let png = try await ContractLoRARender.png(
                of: ContractLoRARender.request(
                    model: model.id, family: family, loraPaths: [placed.path], loraScales: [1]),
                on: engine)
            check.expect(ContractLoRARender.isPNG(png), "a LoRA placed after launch did not render without a rescan")
            check.expect(png != withoutLoRA, "a LoRA placed after launch left the render unchanged")
        }
    }
}
