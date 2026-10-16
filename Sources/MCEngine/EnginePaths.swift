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
    public var modelsLink: URL { home.appendingPathComponent(".mlx-serve/models") }
    public var weights: URL { modelsRoot().appendingPathComponent("Weights") }
}
