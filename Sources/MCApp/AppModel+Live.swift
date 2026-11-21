import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import MCLibrary
import MCModels

// The production wiring: where the app's files live, the bundled engine and the signed catalog.
extension AppModel {
    /// The production app: the bundled engine, the library and queue in Application Support, and the bundled registry.
    /// Starts the engine and the queue in the background.
    public static func live() async throws -> AppModel {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "mlx-create", directoryHint: .isDirectory)
        let modelsRoot = support.appending(path: "Models", directoryHint: .isDirectory)
        let executable = Bundle.main.bundleURL.appending(path: "Contents/MacOS/mlx-serve")
        let paths = EnginePaths(executable: executable, appSupport: support, modelsRoot: { modelsRoot })
        // Created up front so a first run with no weights reaches the "no models" canvas, not a missing-folder crash.
        try FileManager.default.createDirectory(at: paths.weights, withIntermediateDirectories: true)

        let registry = try FamilyRegistry.bundled()
        let libraryRoot = support.appending(path: "Library", directoryHint: .isDirectory)
        let store = try await LibraryStore.open(libraryRoot: libraryRoot, modelsRoot: modelsRoot)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let userAgent = "mlx-create/\(version)"
        // The build's catalog URL (KTD4). Empty means no request, so the bundled catalog is the only source.
        let remoteURL = Self.catalogRemoteURL(
            configured: Bundle.main.object(forInfoDictionaryKey: "MLXCatalogURL") as? String)
        // A catalog that does not verify leaves installs disabled (`installs` stays nil); the rest of the app still launches.
        let catalogStore = try? CatalogStore(
            bundled: try BundledCatalog.fromBundle(),
            cacheDirectory: support.appending(path: "Catalog", directoryHint: .isDirectory),
            keys: PinnedKeys.keys, remoteURL: remoteURL, transport: URLSessionCatalogTransport(userAgent: userAgent))
        let catalog = try? catalogStore?.current().catalog
        let downloader = ModelDownloader(configuration: .init(modelsRoot: modelsRoot, userAgent: userAgent))
        let supervisor = EngineSupervisor(paths: paths, tier: .current)

        let (states, continuation) = AsyncStream<EngineState>.makeStream()
        Task {
            let forwarded = await supervisor.states
            for await state in forwarded { continuation.yield(state) }
        }

        let gate = EngineGate()
        let client = EngineClient(endpoint: { try await gate.endpoint() })
        let model = AppModel(
            store: store, client: client, gate: gate, registry: registry, states: states,
            weightsPath: paths.weights.path, libraryPaths: LibraryPaths(root: libraryRoot, modelsRoot: modelsRoot), supervisor: supervisor,
            engineVersion: bundledEngineVersion(), catalog: catalog, transport: downloader, catalogStore: catalogStore,
            civitaiTransport: URLSessionCivitaiTransport(userAgent: userAgent))
        Task { await model.start() }
        return model
    }

    /// The pinned engine version, written into the bundle from `engine.lock` by `scripts/embed-engine.sh`.
    /// Nil when the bundle has none, for example under `swift test`.
    private static func bundledEngineVersion() -> String? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Resources/ThirdParty/mlx-serve/ENGINE_VERSION")
        let text = try? String(contentsOf: url, encoding: .utf8)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The catalog URL from the build's `MLXCatalogURL` (`MLXC_CATALOG_URL`). Empty, unexpanded or not an absolute
    /// http(s) address means nil, so no request is made (KTD4).
    static func catalogRemoteURL(configured value: String?) -> URL? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            url.host != nil
        else { return nil }
        return url
    }
}
