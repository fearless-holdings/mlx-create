import Foundation

/// Downloads an `InstallPlan` into `Models/.partial/<id>/`, verifies it, and publishes it to `Models/Weights/<org>/<name>/`
/// (plan KTD5, KTD6, KTD8). Public surface is final for the installer lane.
public final class ModelDownloader: Sendable {
    public struct Configuration: Sendable {
        /// The `Models` folder. `Weights/` and `.partial/` are created beneath it.
        public var modelsRoot: URL
        /// Hugging Face base, `https://huggingface.co` in the app. Tests point it at a local Range server.
        public var endpoint: URL
        /// Sent on every request, e.g. `mlx-create/<version>` (KTD20).
        public var userAgent: String
        public var connections: Int
        public var minChunkBytes: Int64
        /// Aggregate throughput below this for `stallTimeout` counts as a stall.
        public var stallTimeout: Duration
        /// Stalls tolerated before the install fails with `stalled`.
        public var maxStalls: Int
        /// Free space required beyond the remaining bytes (KTD8).
        public var headroomBytes: Int64
        /// Reports free bytes for the volume holding the given directory. Injected so tests control preflight.
        public var availableBytes: @Sendable (URL) throws -> Int64

        public init(
            modelsRoot: URL,
            userAgent: String,
            endpoint: URL = URL(string: "https://huggingface.co")!,
            connections: Int = 16,
            minChunkBytes: Int64 = 8 << 20,
            stallTimeout: Duration = .seconds(30),
            maxStalls: Int = 3,
            headroomBytes: Int64 = 1 << 30,
            availableBytes: @escaping @Sendable (URL) throws -> Int64 = DiskSpace.availableForImportantUsage
        ) {
            self.modelsRoot = modelsRoot
            self.userAgent = userAgent
            self.endpoint = endpoint
            self.connections = connections
            self.minChunkBytes = minChunkBytes
            self.stallTimeout = stallTimeout
            self.maxStalls = maxStalls
            self.headroomBytes = headroomBytes
            self.availableBytes = availableBytes
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Final folder for a plan: `Models/Weights/<org>/<name>/`.
    public func destination(for plan: InstallPlan) -> URL {
        InstallStaging.destinationURL(plan, modelsRoot: configuration.modelsRoot)
    }

    /// Runs the install. Consuming the stream drives it; cancelling the consuming task cancels the install and keeps
    /// its partials. Ends after one terminal event.
    public func install(_ plan: InstallPlan) -> AsyncStream<InstallEvent> {
        AsyncStream { continuation in
            continuation.yield(
                InstallEvent(phase: .failed(.invalidPlan("ModelDownloader is not implemented yet")),
                             bytesDone: 0, bytesTotal: plan.totalBytes))
            continuation.finish()
        }
    }

    /// Staged installs left by an earlier run (`Models/.partial/`). Used by the installer to list interrupted installs.
    /// Nothing resumes on its own; the user must ask.
    public static func interruptedInstalls(modelsRoot: URL) -> [StagedInstall] {
        InstallStaging.interrupted(modelsRoot: modelsRoot)
    }
}

/// A staged install found under `Models/.partial/`.
public struct StagedInstall: Sendable, Equatable {
    public let plan: InstallPlan
    public let directory: URL
    /// Bytes currently held by the staging folder, partials and sidecars included.
    public let bytesOnDisk: Int64

    public init(plan: InstallPlan, directory: URL, bytesOnDisk: Int64) {
        self.plan = plan
        self.directory = directory
        self.bytesOnDisk = bytesOnDisk
    }
}
