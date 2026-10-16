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
}

/// Parsed arguments: `--name value` pairs, bare flags and at most one positional path.
struct Options {
    static let valueOptions: Set<String> = ["--source", "--out", "--key", "--catalog-url"]
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
