import Darwin
import Foundation
import MCCatalog
import Testing

@testable import MCEngine

/// R6: the model routes the queue, the installer and the enhancer lease depend on, at both memory tiers
/// (`docs/lld/engine-contract.md` §4). Everything goes through `EngineClient`; a raw request is used only for the body
/// the client never builds.
@Suite(.serialized, .enabled(if: ContractEnvironment.enabled))
struct LifecycleContractTests {
    @Test func theEngineListsTheInstalledFamiliesAndLoadsAndUnloadsThem() async throws {
        try await ContractEngine.run { engine in
            try await runProbe(ContractProbe.modelsListsInstalledFamilies.rawValue, ledger: ContractRun.ledger) { check in
                let registry = try ContractModels.registry()
                check.expect(!registry.families.isEmpty, "the bundled registry lists no families")
                let installed = try await engine.installedImageModels()
                let entries = try await engine.client.models()
                for family in registry.families {
                    let model = try ContractModels.model(for: family, in: installed)
                    check.expect(model.family.id == family.id, "the model installed for \(family.id) resolved to \(model.family.id)")
                    guard let entry = entries.first(where: { $0.id == model.id }) else {
                        check.expect(false, "the engine does not list \(model.id), the model installed for \(family.id)")
                        continue
                    }
                    check.expect(entry.isImage, "\(model.id) does not carry the image capability: \(entry.capabilities)")
                    check.expect(
                        entry.architecture.map { family.architectures.contains($0) } ?? false,
                        "\(model.id) reports architecture \(entry.architecture ?? "none"); \(family.id) is \(family.architectures)"
                    )
                }
            }

            try await runProbe(ContractProbe.modelsLoadUnload.rawValue, ledger: ContractRun.ledger) { check in
                let target = try await smallestImageModel(using: engine)
                try await engine.client.load(model: target.id)
                let afterLoad = try await loadedIDs(in: engine)
                check.expect(afterLoad.contains(target.id), "\(target.id) is not loaded after its load returned 200")
                try await engine.client.unload(model: target.id)
                let afterUnload = try await loadedIDs(in: engine)
                check.expect(!afterUnload.contains(target.id), "\(target.id) is still loaded after its unload returned 200")
            }

            try await runProbe(ContractProbe.modelsUnloadNotResident.rawValue, ledger: ContractRun.ledger) { check in
                // The lease unloads blindly after the engine may have evicted, so an absent model must be a no-op.
                let target = try await smallestImageModel(using: engine)
                let installed = try await engine.installedImageModels()
                guard let absent = installed.first(where: { $0.id != target.id }) else {
                    throw ContractHarnessError.missing("a second installed image model")
                }
                let resident = try await loadedIDs(in: engine)
                check.expect(!resident.contains(absent.id), "\(absent.id) is resident, so this run cannot prove the absent case")
                try await engine.client.unload(model: absent.id)
                let after = try await loadedIDs(in: engine)
                check.expect(!after.contains(absent.id), "\(absent.id) is loaded after unloading a model that was not resident")
            }

            try await runProbe(ContractProbe.modelsLoadUnknownFails.rawValue, ledger: ContractRun.ledger) { check in
                let unknown = "contract-probe/model-that-does-not-exist"
                do {
                    try await engine.client.load(model: unknown)
                    check.expect(false, "loading \(unknown) succeeded")
                } catch let error as EngineError {
                    switch error {
                    case .badRequest, .engineFailure, .modelNotLoaded, .noModel:
                        break
                    case .outOfMemory:
                        throw error
                    default:
                        check.expect(false, "loading \(unknown) mapped to \(error), not to a failure the app reports")
                    }
                } catch {
                    check.expect(false, "loading \(unknown) threw \(error), not an EngineError")
                }
                let loaded = try await loadedIDs(in: engine)
                check.expect(!loaded.contains(unknown), "\(unknown) is reported loaded after its load failed")
            }

            try await runProbe(ContractProbe.imageMissingPrompt400.rawValue, ledger: ContractRun.ledger) { check in
                let installed = try await engine.installedImageModels()
                guard let model = installed.first else { throw ContractHarnessError.missing("an installed image model") }
                let size = model.family.defaultSize
                // The one body the app never builds: no prompt at all. Everything else is what `ImageRequest` sends.
                let body: [String: Any] = ["model": model.id, "size": "\(size.width)x\(size.height)", "seed": 7, "stream": true]
                let response = try await RawHTTP.send(
                    "POST", "v1/images/generations", to: engine.endpoint, key: engine.endpoint.apiKey, json: body)
                check.expect(response.status == 400, "a request with no prompt returned \(response.status): \(response.text)")
                let envelope = ContractErrorEnvelope.decode(response.body)
                check.expect(
                    envelope?.error.message?.isEmpty == false,
                    "the 400 body is not the error envelope the app parses: \(response.text)")
                switch EngineError.fromResponse(status: response.status, body: response.body) {
                case .badRequest:
                    break
                case let mapped:
                    check.expect(false, "the app maps a missing-prompt 400 to \(mapped), not .badRequest")
                }
            }
        }
    }

    @Test func aRescanSeesAModelFolderAddedAfterLaunch() async throws {
        try await ContractEngine.run { engine in
            try await runProbe(ContractProbe.modelsRescanSeesNewFolder.rawValue, ledger: ContractRun.ledger) { check in
                let before = try await engine.client.models()
                check.expect(!before.isEmpty, "the engine listed no model at launch")

                // `MLXC_CONTRACT_MODEL_DIR` is read only for this suite (contract §2), so the folder the engine must
                // discover afterwards goes into a local Weights built from one symlink per model folder, and that
                // directory takes the throwaway Weights path. The launch stays exactly the app's.
                let local = try mirroredWeights(from: ContractEnvironment.modelDirectory, in: engine.root)
                let added = try addSecondName(for: local.firstModelFolder)
                let weights = engine.paths.weights
                guard unlink(weights.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard rename(local.weights.path, weights.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }

                try await engine.client.rescan()
                let after = try await engine.client.models()
                for entry in before {
                    check.expect(after.contains { $0.id == entry.id }, "\(entry.id) left /v1/models after one rescan")
                }
                check.expect(
                    after.contains { $0.id.hasSuffix(added) && $0.isImage },
                    "the folder \(added) added to Weights after launch is not listed after one rescan: \(after.map(\.id)). "
                        + "If the engine resolved --model-dir once at launch, the throwaway Weights must be a real directory "
                        + "from the start (ContractEngine.run needs a weights override)")
            }
        }
    }

    @Test func theSingleSlotTierKeepsAtMostOneModelResident() async throws {
        try await withEnhancerProbe(tier: ContractEngine.singleSlot, probe: ContractProbe.residencySingleSlot.rawValue) {
            engine, _, check in
            let target = try await smallestImageModel(using: engine)
            try await engine.client.load(model: target.id)
            let resident = try await loadedIDs(in: engine)
            check.expect(
                resident.count <= ContractEngine.singleSlot.maxResidentModels,
                "\(resident.count) models are loaded at the single-slot tier: \(resident.sorted())")
            check.expect(resident.contains(target.id), "\(target.id) is not loaded after its load returned 200")
        }
    }

    @Test func theMultiSlotTierKeepsTwoModelsResident() async throws {
        try await withEnhancerProbe(tier: ContractEngine.doubleSlot, probe: ContractProbe.residencyMultiSlot.rawValue) {
            engine, enhancer, check in
            let target = try await smallestImageModel(using: engine)
            try await engine.client.load(model: target.id)
            let resident = try await loadedIDs(in: engine)
            check.expect(
                resident.count <= ContractEngine.doubleSlot.maxResidentModels,
                "\(resident.count) models are loaded at the multi-slot tier: \(resident.sorted())")
            check.expect(resident.contains(target.id), "\(target.id) is not loaded after its load returned 200")
            check.expect(resident.contains(enhancer), "the enhancer is no longer loaded beside \(target.id): \(resident.sorted())")
        }
    }

    /// Both residency probes start from the lease's own order: the enhancer is loaded first, then an image model.
    private func withEnhancerProbe(
        tier: MemoryTier,
        probe id: String,
        _ body: (ContractEngine, String, inout ProbeCheck) async throws -> Void
    ) async throws {
        try await ContractEngine.run(tier: tier) { engine in
            try await runProbe(id, ledger: ContractRun.ledger) { check in
                let enhancer = try ContractModels.enhancerID()
                let listed = try await engine.client.models()
                guard listed.contains(where: { $0.id == enhancer }) else {
                    throw ContractHarnessError.missing("the enhancer \(enhancer) in the model directory")
                }
                try await engine.client.load(model: enhancer)
                let resident = try await loadedIDs(in: engine)
                check.expect(resident.contains(enhancer), "the enhancer is not loaded after its load returned 200")
                try await body(engine, enhancer, &check)
            }
        }
    }
}

/// The engine ids `/v1/models` reports as loaded.
private func loadedIDs(in engine: ContractEngine) async throws -> Set<String> {
    let entries = try await engine.client.models()
    return Set(entries.filter(\.loaded).map(\.id))
}

/// The installed image model with the smallest catalog RAM need, so a load probe spends the least memory. Falls back to
/// the first installed model when the catalog names none of them.
private func smallestImageModel(using engine: ContractEngine) async throws -> InstalledModelRecord {
    let installed = try await engine.installedImageModels()
    let catalog = try Catalog.decodeValidated(BundledCatalog.fromBundle().bytes)
    var ramGB: [String: Double] = [:]
    for model in catalog.models where model.kind == .image { ramGB[model.repo] = model.ramGB }
    let best = installed.min { left, right in
        (ramGB[left.id] ?? .greatestFiniteMagnitude) < (ramGB[right.id] ?? .greatestFiniteMagnitude)
    }
    guard let best else { throw ContractHarnessError.missing("an installed image model") }
    return best
}

/// A Weights directory that can still be extended: real folders wherever the engine expects them, one symlink per model
/// folder. Nothing here is written into `MLXC_CONTRACT_MODEL_DIR`.
private struct MirroredWeights {
    let weights: URL
    let firstModelFolder: URL
}

private func mirroredWeights(from source: URL, in root: URL) throws -> MirroredWeights {
    let weights = root.appending(path: "Models/WeightsLocal", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
    guard let first = try mirrorModelFolders(from: source, into: weights) else {
        throw ContractHarnessError.missing("a model folder under \(source.path)")
    }
    return MirroredWeights(weights: weights, firstModelFolder: first)
}

/// Mirrors every directory of `source` into `destination`: a folder holding model files becomes a symlink, every other
/// directory is recreated so a model folder can be added beside it. Returns the first model folder mirrored.
private func mirrorModelFolders(from source: URL, into destination: URL) throws -> URL? {
    let fm = FileManager.default
    var first: URL?
    for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
        let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDirectory else { continue }
        let mirror = destination.appending(path: child.lastPathComponent)
        if isModelFolder(child) {
            try fm.createSymbolicLink(at: mirror, withDestinationURL: child)
            if first == nil { first = mirror }
        } else {
            try fm.createDirectory(at: mirror, withIntermediateDirectories: true)
            if let nested = try mirrorModelFolders(from: child, into: mirror), first == nil { first = nested }
        }
    }
    return first
}

/// A folder the engine loads as a model: a config file or a weight file sits directly inside it.
private func isModelFolder(_ folder: URL) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: folder.appending(path: "config.json").path) { return true }
    let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.contains { $0.hasSuffix(".safetensors") }
}

/// A second name for one model folder, so a folder the engine never saw at launch appears without new weights.
private func addSecondName(for modelFolder: URL) throws -> String {
    let fm = FileManager.default
    let target = (try? fm.destinationOfSymbolicLink(atPath: modelFolder.path)) ?? modelFolder.path
    let name = "\(modelFolder.lastPathComponent)-rescan-probe"
    try fm.createSymbolicLink(
        at: modelFolder.deletingLastPathComponent().appending(path: name),
        withDestinationURL: URL(fileURLWithPath: target))
    return name
}
