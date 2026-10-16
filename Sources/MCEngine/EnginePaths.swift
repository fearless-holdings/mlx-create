import Foundation

/// Filesystem layout for one engine (LLD §5.1). The executable URL is an input so the same code
/// runs the bundled binary in the app and the extracted tarball binary in the smoke harness.
public struct EnginePaths: Sendable {
    public let executable: URL
    public let appSupport: URL
    /// Read on every start(): the Models root is relocatable (D17).
    public let modelsRoot: @Sendable () -> URL

    public init(executable: URL, appSupport: URL, modelsRoot: @escaping @Sendable () -> URL) {
        self.executable = executable
        self.appSupport = appSupport
        self.modelsRoot = modelsRoot
    }

    /// HOME for the engine.
    public var home: URL { appSupport.appendingPathComponent("Engine") }
    public var pidFile: URL { home.appendingPathComponent("engine.pid") }
    /// Held with `flock` for the app's whole life (D28). A reap of a recorded engine runs only while it is held.
    public var appLock: URL { Self.appLockURL(appSupport: appSupport) }
    public var modelsLink: URL { home.appendingPathComponent(".mlx-serve/models") }
    public var weights: URL { modelsRoot().appendingPathComponent("Weights") }

    /// `<Application Support>/mlx-create`: the root the production app uses. Single-instance lock lives under it (D28).
    public static func defaultAppSupport() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "mlx-create", directoryHint: .isDirectory)
    }

    /// `Engine/app.lock` under `appSupport`.
    public static func appLockURL(appSupport: URL) -> URL {
        appSupport.appending(path: "Engine", directoryHint: .isDirectory).appending(path: "app.lock")
    }
}
