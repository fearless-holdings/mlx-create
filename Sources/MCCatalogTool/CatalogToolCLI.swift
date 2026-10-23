import Foundation
import MCCatalog

/// Failures the `mc-catalog` tool reports. Each maps to a non-zero exit with a message on stderr.
enum CatalogToolError: Error, Equatable, CustomStringConvertible {
    case usage(String)
    case diffNotAcknowledged
    case keyNotPinned(String)
    case keyExists(String)
    case devKeyWithCatalogURL(String)
    case hub(String)
    case source(String)

    var description: String {
        switch self {
        case .usage(let message): return "usage: \(message)"
        case .diffNotAcknowledged:
            return "refusing to sign: review the diff printed by `build`, then re-run sign with --acknowledge-diff"
        case .keyNotPinned(let id):
            return "refusing to sign: key \(id) is not in PinnedKeys.keys, so the app could not verify the result"
        case .keyExists(let path): return "refusing to overwrite existing key at \(path)"
        case .devKeyWithCatalogURL(let id):
            return
                "release gate: development key \(id) is pinned while a catalog URL is set; remove the dev key or clear MLXC_CATALOG_URL"
        case .hub(let message): return "Hugging Face: \(message)"
        case .source(let message): return "source catalog: \(message)"
        }
    }
}

/// Command-line entry point for `mc-catalog` (`docs/lld/models.md` §4, §11).
enum CatalogToolCLI {
    static let usage = """
        mc-catalog keygen [--out PATH]
        mc-catalog build --source catalog/models.src.json --out Sources/MCCatalog/Resources/catalog.json
        mc-catalog sign CATALOG [--key PATH] --acknowledge-diff
        mc-catalog verify CATALOG [--release] [--catalog-url URL]
        mc-catalog lora classify FILE.safetensors [--family FAMILY]
        """

    static func run(_ arguments: [String]) async -> Int32 {
        do {
            try await dispatch(arguments)
            return 0
        } catch let error as CatalogToolError {
            if case .usage = error {
                FileHandle.standardError.write(Data("\(error)\n\(usage)\n".utf8))
                return 2
            }
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    static func dispatch(_ arguments: [String]) async throws {
        guard let command = arguments.first else { throw CatalogToolError.usage("missing command") }
        let options = try Options(arguments.dropFirst())
        switch command {
        case "keygen":
            try keygen(options)
        case "build":
            try await build(options)
        case "sign":
            try sign(options)
        case "verify":
            try verify(options)
        case "lora":
            try lora(options)
        default:
            throw CatalogToolError.usage("unknown command \(command)")
        }
    }

    private static func keygen(_ options: Options) throws {
        let url = try options.url("--out") ?? DevKeyStore.defaultURL
        let key = try DevKeyStore.generate(at: url)
        let publicKey = key.publicKey.rawRepresentation
        print("private key: \(url.path) (mode 0600, never commit)")
        print("public key (base64): \(publicKey.base64EncodedString())")
        print("key id: \(PinnedCatalogKey.keyId(for: publicKey))")
        print("pin the public key in Sources/MCCatalog/Catalog/PinnedKeys.swift")
    }

    private static func build(_ options: Options) async throws {
        let sourceURL = try options.required("--source")
        let outURL = try options.required("--out")
        let source = try SourceCatalog.load(Data(contentsOf: sourceURL))
        let previous: Catalog?
        if FileManager.default.fileExists(atPath: outURL.path) {
            previous = try Catalog.decodeValidated(Data(contentsOf: outURL))
        } else {
            previous = nil
        }
        let build = try await CatalogBuilder(hub: URLSessionHubClient()).build(source: source, previous: previous)
        try build.bytes.write(to: outURL, options: .atomic)
        print("wrote \(outURL.path) sequence \(build.catalog.sequence) (\(build.catalog.models.count) model(s))")
        for line in CatalogDiff.lines(previous: previous, next: build.catalog) { print(line) }
        for path in build.skipped { print("skipped (not an allowed model file): \(path)") }
        print("review the diff, then run: mc-catalog sign \(outURL.path) --acknowledge-diff")
    }

    private static func sign(_ options: Options) throws {
        let catalogURL = try options.positional()
        let keyURL = try options.url("--key") ?? DevKeyStore.defaultURL
        let key = try DevKeyStore.load(from: keyURL)
        let sigURL = try CatalogSigner.sign(
            catalogAt: catalogURL, with: key, pinned: PinnedKeys.keys,
            acknowledgedDiff: options.flags.contains("--acknowledge-diff"))
        print("signed \(catalogURL.path) -> \(sigURL.lastPathComponent)")
    }

    private static func verify(_ options: Options) throws {
        let catalogURL = try options.positional()
        let result = try CatalogVerifier.verify(
            catalogAt: catalogURL, pinned: PinnedKeys.keys, release: options.flags.contains("--release"),
            catalogURL: options.values["--catalog-url"] ?? "")
        print("verified \(catalogURL.path) sequence \(result.sequence) key \(result.keyId)")
    }

    /// `lora classify`: the LoRA gate harness's fit check (KTD8). Reads only the header; prints one JSON line.
    private static func lora(_ options: Options) throws {
        guard options.positionals.count == 2, options.positionals.first == "classify" else {
            throw CatalogToolError.usage("expected `lora classify FILE.safetensors [--family FAMILY]`")
        }
        let fit = try LoRAFitReport.classify(
            fileAt: URL(fileURLWithPath: options.positionals[1]), familyID: options.values["--family"],
            registry: try FamilyRegistry.bundled())
        print(try fit.jsonLine())
    }
}

/// Parsed arguments: `--name value` pairs, bare flags and at most one positional path.
struct Options {
    static let valueOptions: Set<String> = ["--source", "--out", "--key", "--catalog-url", "--family"]
    static let flagOptions: Set<String> = ["--release", "--acknowledge-diff"]

    private(set) var values: [String: String] = [:]
    private(set) var flags: Set<String> = []
    private(set) var positionals: [String] = []

    init(_ arguments: ArraySlice<String>) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if Self.flagOptions.contains(argument) {
                flags.insert(argument)
            } else if Self.valueOptions.contains(argument) {
                guard let value = iterator.next() else { throw CatalogToolError.usage("\(argument) needs a value") }
                values[argument] = value
            } else if argument.hasPrefix("--") {
                throw CatalogToolError.usage("unknown option \(argument)")
            } else {
                positionals.append(argument)
            }
        }
    }

    func url(_ name: String) throws -> URL? {
        values[name].map { URL(fileURLWithPath: $0) }
    }

    func required(_ name: String) throws -> URL {
        guard let url = try url(name) else { throw CatalogToolError.usage("\(name) is required") }
        return url
    }

    func positional() throws -> URL {
        guard positionals.count == 1, let path = positionals.first else {
            throw CatalogToolError.usage("expected exactly one catalog path")
        }
        return URL(fileURLWithPath: path)
    }
}

/// The outcome of one `lora classify` run, printed as one JSON line (KTD8). `family` and `variant` are omitted when
/// the file matches no family; `reason` is never empty, so a rejection always carries its cause.
struct LoRAFitReport: Encodable, Equatable {
    enum Result: String, Encodable {
        case matched
        case unmatched
        case ambiguous
    }

    let result: Result
    let family: String?
    let variant: String?
    let reason: String

    /// Classifies the safetensors header of `url`. Fingerprint rules stay in `classifyLoRA` and `families.json`; the
    /// header read is here only because the tool depends on `MCCatalog` alone. `familyID` restricts the comparison to
    /// one family, the form a candidate list carrying an expected family uses.
    static func classify(fileAt url: URL, familyID: String?, registry: FamilyRegistry) throws -> LoRAFitReport {
        let shapes = try LoRAHeader.shapes(fileAt: url)
        guard let familyID else { return classify(shapes: shapes, registry: registry) }
        guard let family = registry.families.first(where: { $0.id == familyID }) else {
            throw CatalogToolError.usage("unknown family \(familyID)")
        }
        return classify(shapes: shapes, in: family)
    }

    private static func classify(shapes: [String: [Int]], registry: FamilyRegistry) -> LoRAFitReport {
        switch registry.classifyLoRA(tensors: shapes) {
        case .family(let id, let variant):
            return LoRAFitReport(result: .matched, family: id, variant: variant, reason: "matches the \(id) fingerprint")
        case .unmatched(let supported):
            return LoRAFitReport(
                result: .unmatched, family: nil, variant: nil,
                reason: "no fingerprinted family matches; supported: \(supported.joined(separator: ", "))")
        case .ambiguous(let ids):
            return LoRAFitReport(
                result: .ambiguous, family: nil, variant: nil,
                reason: "matches several families: \(ids.joined(separator: ", "))")
        }
    }

    /// `classifyLoRA` never picks between two families; with one named, the answer is definite or a mismatch.
    private static func classify(shapes: [String: [Int]], in family: ModelFamily) -> LoRAFitReport {
        let fingerprints = family.loraFingerprints ?? []
        let matching = fingerprints.filter { $0.matches(tensors: shapes) }
        guard let first = matching.first else {
            var reason = "does not match the \(family.id) fingerprint"
            if fingerprints.isEmpty {
                reason = "\(family.id) accepts no LoRAs: it has no fingerprint"
            }
            return LoRAFitReport(result: .unmatched, family: nil, variant: nil, reason: reason)
        }
        let variants = Set(matching.map(\.variant))
        return LoRAFitReport(
            result: .matched, family: family.id, variant: variants.count == 1 ? first.variant : nil,
            reason: "matches the \(family.id) fingerprint")
    }

    /// The single JSON line the command prints.
    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Why the header of a LoRA file could not be read for classification. `MCLibrary.SafetensorsHeader` owns the full
/// validation the app needs at import; this reader takes only the names and shapes the fingerprint matcher uses.
enum LoRAHeaderError: Error, CustomStringConvertible {
    case notSafetensors(found: String)
    case unreadable(reason: String)
    case headerLengthOutOfRange(declared: UInt64, fileSize: UInt64)
    case malformed(reason: String)

    var description: String {
        switch self {
        case .notSafetensors(let found): "not a .safetensors file (extension \"\(found)\")"
        case .unreadable(let reason): "the file could not be read: \(reason)"
        case .headerLengthOutOfRange(let declared, let fileSize):
            "the header length (\(declared) bytes) does not fit a \(fileSize)-byte file"
        case .malformed(let reason): "the safetensors header is not valid: \(reason)"
        }
    }
}

/// The tensor names and shapes of a safetensors header. Only the 8-byte length prefix and the header JSON are read;
/// tensor data is never touched, so a multi-gigabyte file costs a few kilobytes.
enum LoRAHeader {
    /// Headers larger than this are refused without being read, matching the app's reader.
    static let maxHeaderLength: UInt64 = 100 * 1024 * 1024

    static func shapes(fileAt url: URL) throws -> [String: [Int]] {
        let ext = url.pathExtension
        guard ext.lowercased() == "safetensors" else { throw LoRAHeaderError.notSafetensors(found: ext) }
        let fileSize: UInt64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        } catch {
            throw LoRAHeaderError.unreadable(reason: error.localizedDescription)
        }
        guard fileSize >= 8 else {
            throw LoRAHeaderError.headerLengthOutOfRange(declared: 0, fileSize: fileSize)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LoRAHeaderError.unreadable(reason: error.localizedDescription)
        }
        defer { try? handle.close() }
        let declared = declaredLength(try read(handle, count: 8))
        guard declared <= maxHeaderLength, declared <= fileSize - 8 else {
            throw LoRAHeaderError.headerLengthOutOfRange(declared: declared, fileSize: fileSize)
        }
        return try parse(try read(handle, count: Int(declared)))
    }

    /// The little-endian header length in the 8-byte prefix.
    private static func declaredLength(_ prefix: Data) -> UInt64 {
        prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
    }

    private static func read(_ handle: FileHandle, count: Int) throws -> Data {
        let data: Data?
        do {
            data = try handle.read(upToCount: count)
        } catch {
            throw LoRAHeaderError.unreadable(reason: error.localizedDescription)
        }
        guard let data, data.count == count else {
            throw LoRAHeaderError.unreadable(reason: "expected \(count) bytes")
        }
        return data
    }

    /// Tensor name to shape. `__metadata__` is skipped; a tensor without an integer shape is malformed.
    private static func parse(_ header: Data) throws -> [String: [Int]] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: header)
        } catch {
            throw LoRAHeaderError.malformed(reason: error.localizedDescription)
        }
        guard let entries = object as? [String: Any] else {
            throw LoRAHeaderError.malformed(reason: "the header is not a JSON object")
        }
        var shapes: [String: [Int]] = [:]
        for (name, value) in entries where name != "__metadata__" {
            guard let entry = value as? [String: Any], let shape = entry["shape"] as? [Any] else {
                throw LoRAHeaderError.malformed(reason: "tensor \"\(name)\" has no shape")
            }
            let values = shape.compactMap { $0 as? Int }
            guard values.count == shape.count else {
                throw LoRAHeaderError.malformed(reason: "tensor \"\(name)\" has a non-integer shape")
            }
            shapes[name] = values
        }
        return shapes
    }
}
