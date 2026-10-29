import Foundation
import MCCatalog
import MCEngine
import MCLibrary

/// One LoRA file under `MLXC_CONTRACT_LORA_DIR`, with the family its safetensors header says it fits. The header
/// decides, never the file name or the folder the file sits in (KTD4): classification is
/// `FamilyRegistry.classifyLoRA`, the call `mc-catalog lora classify` makes.
struct ContractLoRAFile: Sendable, Equatable {
    let url: URL
    let family: String
    /// The size variant the matching layouts named, or nil when they name none (KTD6).
    let variant: String?
    let sizeBytes: Int64

    /// The absolute path the engine receives in `lora_paths`, outside its model directory as the app's requests are.
    var path: String { url.path }
    var fileName: String { url.lastPathComponent }
}

/// An always-on shelf entry of the bundled catalog (D44) together with the file it names on disk.
struct ContractAlwaysOnLoRA: Sendable {
    let entry: LoRAShelfEntry
    let file: ContractLoRAFile

    var family: String { entry.family }
    /// The scale the app applies the file at: the entry's `tested_scale`.
    var scale: Double { entry.testedScale }
}

/// Resolves the LoRA files the LoRA probes send (`docs/lld/engine-contract.md` §3, §4). A file is usable only when
/// its header classifies to exactly one family; a missing prerequisite throws `ContractHarnessError.missing`, so the
/// run stays incomplete and writes no result (R8).
struct ContractLoRAs: Sendable {
    private let byFamily: [String: [ContractLoRAFile]]
    private let alwaysOnEntries: [LoRAShelfEntry]
    private let resolvedAlwaysOn: [ContractAlwaysOnLoRA]
    private let alwaysOnPaths: Set<String>

    /// The directory `MLXC_CONTRACT_LORA_DIR` names.
    init(registry: FamilyRegistry) throws {
        try self.init(directory: ContractEnvironment.loraDirectory, registry: registry)
    }

    init(directory: URL?, registry: FamilyRegistry, catalog: [LoRAShelfEntry]? = nil) throws {
        guard let directory else {
            throw ContractHarnessError.missing("MLXC_CONTRACT_LORA_DIR, the directory of <family id>/*.safetensors files")
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw ContractHarnessError.missing("the LoRA directory \(directory.path) (MLXC_CONTRACT_LORA_DIR)")
        }
        let entries = try catalog ?? Self.shelfEntries()
        let files = Self.classified(in: directory, registry: registry)
        let alwaysOn = entries.filter(\.alwaysOn)
        var resolved: [ContractAlwaysOnLoRA] = []
        for entry in alwaysOn {
            guard let file = files[entry.family]?.first(where: { Self.names(entry, $0) }) else { continue }
            resolved.append(ContractAlwaysOnLoRA(entry: entry, file: file))
        }
        self.byFamily = files
        self.alwaysOnEntries = alwaysOn
        self.resolvedAlwaysOn = resolved
        self.alwaysOnPaths = Set(resolved.map(\.file.path))
    }

    /// Every classified file of `family`, always-on files included: the set the cap probe builds from.
    func files(for family: ModelFamily) -> [ContractLoRAFile] { byFamily[family.id] ?? [] }

    /// The user LoRA files of `family`: the classified files minus the family's always-on files.
    func userFiles(for family: ModelFamily) -> [ContractLoRAFile] {
        files(for: family).filter { !alwaysOnPaths.contains($0.path) }
    }

    /// The first user file of `family`, or a thrown prerequisite naming what to add.
    func first(for family: ModelFamily) throws -> ContractLoRAFile {
        let candidates = files(for: family)
        let users = userFiles(for: family)
        guard let file = users.first else {
            throw ContractHarnessError.missing(
                "a LoRA file for family \(family.id) in MLXC_CONTRACT_LORA_DIR: "
                    + "found \(candidates.count) classified files, \(candidates.count - users.count) of them always-on")
        }
        return file
    }

    /// The first family in registry order that has a user LoRA file, with that file.
    func firstFamilyWithAUserFile(in registry: FamilyRegistry) throws -> (family: ModelFamily, file: ContractLoRAFile) {
        for family in registry.families where family.acceptsLoRAs {
            if let file = userFiles(for: family).first { return (family, file) }
        }
        throw ContractHarnessError.missing("a LoRA file in MLXC_CONTRACT_LORA_DIR whose header matches a shipped family")
    }

    /// `count` distinct files of `family`, or a thrown prerequisite naming how many were found. User files come first:
    /// an always-on file is the largest one the library holds and need not sit in the engine's memory for a cap probe.
    func files(for family: ModelFamily, requiring count: Int) throws -> [ContractLoRAFile] {
        let users = userFiles(for: family)
        let candidates = users.count >= count ? users : files(for: family)
        guard candidates.count >= count else {
            throw ContractHarnessError.missing(
                "\(count) LoRA files classified as \(family.id) in MLXC_CONTRACT_LORA_DIR (found \(candidates.count))")
        }
        return Array(candidates.prefix(count))
    }

    /// The family the cap probe runs on: the first in registry order with `count` classified files.
    func family(accepting count: Int, registry: FamilyRegistry) throws -> ModelFamily {
        let accepting = registry.families.filter(\.acceptsLoRAs)
        if let family = accepting.first(where: { files(for: $0).count >= count }) { return family }
        let found = accepting.map { "\($0.id): \(files(for: $0).count)" }.joined(separator: ", ")
        throw ContractHarnessError.missing("\(count) LoRA files classified for one family in MLXC_CONTRACT_LORA_DIR (classified: \(found))")
    }

    /// A file whose header says it belongs to a family other than `family`, so the engine is the one that rejects it.
    /// A user file is preferred: an always-on file is the largest one the library holds.
    func fileFromAnotherFamily(than family: ModelFamily) throws -> ContractLoRAFile {
        let otherIDs = byFamily.keys.filter { $0 != family.id }.sorted()
        for id in otherIDs {
            if let file = byFamily[id]?.first(where: { !alwaysOnPaths.contains($0.path) }) { return file }
        }
        for id in otherIDs {
            if let file = byFamily[id]?.first { return file }
        }
        throw ContractHarnessError.missing("a LoRA file classified as a family other than \(family.id) in MLXC_CONTRACT_LORA_DIR")
    }

    /// The always-on LoRAs the bundled catalog ships, each with the file it names on disk.
    func alwaysOn() throws -> ContractAlwaysOnLoRA {
        if let first = resolvedAlwaysOn.first { return first }
        guard let entry = alwaysOnEntries.first else {
            throw ContractHarnessError.missing("an always-on entry in the bundled catalog's lora_shelf")
        }
        // The app stores the file as `<sha256 prefix>-base-<sha256 prefix>.safetensors` under `LoRAs/<family>/`.
        let sha = entry.sha256
        let stored = "\(sha.prefix(10))-base-\(sha.prefix(8)).safetensors"
        throw ContractHarnessError.missing(
            "the \(entry.family) always-on LoRA \(entry.filename) (\(entry.sizeBytes) bytes) in MLXC_CONTRACT_LORA_DIR, "
                + "as MLXCreate stores it: \(stored)")
    }

    // MARK: - Reading the directory

    private static func classified(in directory: URL, registry: FamilyRegistry) -> [String: [ContractLoRAFile]] {
        var byFamily: [String: [ContractLoRAFile]] = [:]
        for url in safetensorFiles(in: directory) {
            guard let header = try? SafetensorsHeader.read(from: url) else { continue }
            guard case .family(let family, let variant) = registry.classifyLoRA(tensors: header.shapes) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            byFamily[family, default: []].append(
                ContractLoRAFile(url: url, family: family, variant: variant, sizeBytes: size))
        }
        // Names sort the files, so which file a probe sends does not depend on the order the volume lists them in.
        return byFamily.mapValues { files in files.sorted { $0.fileName < $1.fileName } }
    }

    private static func safetensorFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "safetensors" {
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// Whether `file` is the file `entry` names: the catalog's own file name, the app's `<sha256 prefix>` file name,
    /// or its pinned size. Identity, not classification: the family still comes from the header.
    private static func names(_ entry: LoRAShelfEntry, _ file: ContractLoRAFile) -> Bool {
        file.fileName == entry.filename || file.fileName.hasPrefix(entry.sha256.prefix(10))
            || file.sizeBytes == entry.sizeBytes
    }

    /// The bundled catalog's shelf entries, decoded with the app's own `LoRAShelfEntry`.
    private static func shelfEntries() throws -> [LoRAShelfEntry] {
        let bytes = try BundledCatalog.fromBundle().bytes
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let shelf = root["lora_shelf"] as? [Any]
        else { throw ContractHarnessError.missing("an lora_shelf array in the bundled catalog") }
        let decoder = JSONDecoder()
        return try shelf.map { try decoder.decode(LoRAShelfEntry.self, from: JSONSerialization.data(withJSONObject: $0)) }
    }
}

/// The no-LoRA render of one family, made once and reused, so `lora.scale-zero` compares against the same bytes
/// `lora.applies` compared against (KTD4: byte equality inside one engine run, never a golden).
actor ContractLoRABaseline {
    private var renders: [String: Data] = [:]

    func png(for familyID: String, request: ImageRequest, on engine: ContractEngine) async throws -> Data {
        if let saved = renders[familyID] { return saved }
        let data = try await ContractLoRARender.png(of: request, on: engine)
        renders[familyID] = data
        return data
    }
}

/// What every LoRA probe sends and reads: a request built from the family record, one render, and the model made
/// resident first, the way the executor does before it streams a job.
enum ContractLoRARender {
    /// The fixed benign prompt of every LoRA render.
    static let prompt = "a calm lake at dawn, soft light on still water"
    /// The fixed seed of every LoRA render, so two renders differ only by their LoRA stack.
    static let seed: UInt32 = 42

    /// The family record `id` names, or a thrown prerequisite for a catalog entry no record covers.
    static func family(_ id: String, in registry: FamilyRegistry) throws -> ModelFamily {
        guard let family = registry.families.first(where: { $0.id == id }) else {
            throw ContractHarnessError.missing("family \(id) in families.json (the bundled catalog names its always-on LoRA)")
        }
        return family
    }

    /// The family's smallest offered size: where every LoRA byte comparison runs.
    static func smallestSize(of family: ModelFamily) -> ImageSize {
        if let smallest = family.sizePresets.min(by: {
            ($0.width * $0.height, $0.width) < ($1.width * $1.height, $1.width)
        }) {
            return smallest
        }
        return ImageSize(width: family.sizeGrid.min, height: family.sizeGrid.min)
    }

    /// The steps the app sends: none for a family whose checkpoint fixes them, else the family's default.
    static func steps(of family: ModelFamily) -> Int? {
        family.stepsAreFixed ? nil : family.steps.defaultSteps
    }

    /// The request the probes send: one of the family's own sizes, no guidance and no negative prompt (what
    /// `GenerationComposer` builds for every shipped record), the fixed prompt and seed, and LoRA paths outside the
    /// engine's model directory, as the app's library paths are.
    static func request(
        model: String, family: ModelFamily, loraPaths: [String]? = nil, loraScales: [Double]? = nil
    ) -> ImageRequest {
        let size = smallestSize(of: family)
        return ImageRequest(
            model: model, prompt: prompt, width: size.width, height: size.height, steps: steps(of: family),
            guidance: nil, seed: Self.seed, loraPaths: loraPaths, loraScales: loraScales)
    }

    /// Loads the model unless the engine already holds it, as the executor's `makeResident` does before a stream.
    static func makeResident(_ model: InstalledModelRecord, on engine: ContractEngine) async throws {
        let entries = try await engine.client.models()
        guard entries.first(where: { $0.id == model.id })?.loaded != true else { return }
        try await engine.client.load(model: model.id)
    }

    /// The single completed frame's PNG. A stream that ends without one is the app's own `streamEndedWithoutComplete`.
    static func png(of request: ImageRequest, on engine: ContractEngine) async throws -> Data {
        var png: Data?
        for try await event in engine.client.generateImage(request) {
            if case .completed(let data) = event { png = data }
        }
        guard let png else { throw EngineError.streamEndedWithoutComplete }
        return png
    }

    /// Runs `body` and reports what it threw instead of rethrowing, except a memory refusal: that must stay
    /// inconclusive for the whole run (KTD7), so it propagates.
    static func attempt<T>(_ body: () async throws -> T) async throws -> Result<T, Error> {
        do {
            return .success(try await body())
        } catch let error as EngineError {
            if case .outOfMemory = error { throw error }
            return .failure(error)
        } catch {
            return .failure(error)
        }
    }

    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    /// Whether `data` starts with the PNG signature.
    static func isPNG(_ data: Data) -> Bool { data.prefix(8).elementsEqual(pngSignature) }

    /// A file under the run's throwaway root that did not exist when the engine started, holding the same bytes as
    /// `file`: a hardlink, else a symlink, else a copy. Nothing is placed in the LoRA directory.
    static func placedAfterLaunch(_ file: ContractLoRAFile, in root: URL) throws -> URL {
        let directory = root.appending(path: "ContractLoRAs", directoryHint: .isDirectory)
            .appending(path: "after-launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "placed-after-launch-\(file.fileName)")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.linkItem(at: file.url, to: destination)
        } catch {
            do {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: file.url)
            } catch {
                try FileManager.default.copyItem(at: file.url, to: destination)
            }
        }
        return destination
    }
}

/// Keeps a verbatim engine body for the probes that match on its text, under
/// `NSTemporaryDirectory()/mlxc-contract-captures/<engine version>/`. Never in the repository, never in the scratch
/// root the harness deletes.
enum ContractLoRACapture {
    @discardableResult
    static func save(_ body: Data, named name: String, engineVersion: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "mlxc-contract-captures", directoryHint: .isDirectory)
            .appending(path: engineVersion, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try body.write(to: url, options: .atomic)
        return url
    }
}
