import CryptoKit
import Foundation
import Testing

@testable import MCModels

private let pythonAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

/// Runs `Fixtures/range_server.py` on a free loopback port for the lifetime of the value.
final class RangeServer: @unchecked Sendable {
    private let process = Process()
    let port: Int
    private let session = URLSession(configuration: .ephemeral)

    init() throws {
        let ready = FileManager.default.temporaryDirectory.appending(path: "range-\(UUID().uuidString).port")
        let script = try #require(Bundle.module.url(forResource: "range_server", withExtension: "py", subdirectory: "Fixtures"))
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--ready-file", ready.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path) {
            try #require(Date() < deadline, "range server did not start")
            Thread.sleep(forTimeInterval: 0.02)
        }
        let text = try String(contentsOf: ready, encoding: .utf8)
        port = try #require(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    deinit { process.terminate() }

    func control(_ body: [String: Any]) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/__control")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await session.data(for: request)
    }

    func stats() async throws -> ServerStats {
        let (data, _) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/__stats")!)
        return try JSONDecoder().decode(ServerStats.self, from: data)
    }
}

struct ServerStats: Decodable {
    struct Request: Decodable {
        let key: String
        let range: String?
        let status: Int
        let ua: String?
        let cookie: String?
    }

    let requests: [Request]
    let bytesServed: [String: Int64]

    enum CodingKeys: String, CodingKey {
        case requests
        case bytesServed = "bytes_served"
    }
}

/// Deterministic payloads served by the Range server, with the matching `InstallPlan`.
final class Scenario {
    static let revision = String(repeating: "ab", count: 20)

    let server: RangeServer
    let served: TemporaryDirectory
    let models: TemporaryDirectory
    let plan: InstallPlan
    private(set) var payloads: [String: Data] = [:]
    private var sources: [String: URL] = [:]
    private var etags: [String: String] = [:]

    init(server: RangeServer, files: [(path: String, size: Int, seed: UInt8)]) throws {
        self.server = server
        served = try TemporaryDirectory()
        models = try TemporaryDirectory()
        var entries: [InstallPlan.File] = []
        for file in files {
            let data = Scenario.payload(size: file.size, seed: file.seed)
            let url = served.url.appending(path: UUID().uuidString)
            try data.write(to: url)
            sources[file.path] = url
            payloads[file.path] = data
            etags[file.path] = "\"v1-\(file.seed)\""
            entries.append(.init(path: file.path, size: Int64(file.size), sha256: Scenario.sha256Hex(data)))
        }
        plan = InstallPlan(modelID: "test/model", repo: "org/model", revision: Scenario.revision, files: entries)
    }

    func key(_ path: String) -> String { "/org/model/resolve/\(Scenario.revision)/\(path)" }

    /// Sends the current file table to the server. Call again after changing an ETag or overwriting bytes.
    func publish() async throws {
        var table: [String: Any] = [:]
        for (path, url) in sources {
            table[key(path)] = ["path": url.path, "etag": etags[path]!, "linked_etag": "\"linked\""]
        }
        try await server.control(["files": table])
    }

    func changeEtag(_ path: String) async throws {
        etags[path] = "\"v2-\(path)\""
        try await publish()
    }

    /// Replaces the served bytes of `path` with different content of the same size.
    func overwrite(_ path: String, seed: UInt8) throws {
        let size = payloads[path]!.count
        let other = Scenario.payload(size: size, seed: seed)
        try other.write(to: sources[path]!)
    }

    func downloader(
        connections: Int = 4, stallTimeout: Duration = .seconds(1), maxStalls: Int = 3,
        available: Int64 = .max / 4
    ) -> ModelDownloader {
        ModelDownloader(
            configuration: .init(
                modelsRoot: models.url,
                userAgent: "mlx-create/test",
                endpoint: URL(string: "http://127.0.0.1:\(server.port)")!,
                connections: connections,
                minChunkBytes: 256 << 10,
                stallTimeout: stallTimeout,
                maxStalls: maxStalls,
                availableBytes: { _ in available }))
    }

    var staging: URL { InstallStaging.stagingURL(plan, modelsRoot: models.url) }
    var destination: URL { InstallStaging.destinationURL(plan, modelsRoot: models.url) }

    static func payload(size: Int, seed: UInt8) -> Data {
        var data = Data(count: size)
        var x = UInt32(seed) &+ 1
        data.withUnsafeMutableBytes { raw in
            for i in 0..<size {
                x = x &* 1_664_525 &+ 1_013_904_223
                raw[i] = UInt8(truncatingIfNeeded: x >> 24)
            }
        }
        return data
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func collect(_ downloader: ModelDownloader, _ plan: InstallPlan) async -> [InstallEvent] {
    var events: [InstallEvent] = []
    let run = await downloader.install(plan)
    for await event in run.events { events.append(event) }
    return events
}

/// Consumes the install until `bytes` have landed, then cancels it, which keeps its partials. Iteration then drains to
/// the terminal event, so the cancelled install has released its staging lock when this returns.
private func interrupt(_ downloader: ModelDownloader, _ plan: InstallPlan, after bytes: Int64) async -> Bool {
    let run = await downloader.install(plan)
    var stopped = false
    for await event in run.events where !stopped && event.bytesDone >= bytes {
        stopped = true
        run.cancel()
    }
    return stopped
}

private func installError(_ events: [InstallEvent]) -> InstallError? {
    if case .failed(let error)? = events.last?.phase { return error }
    return nil
}

private func fileNames(under root: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { ($0 as? URL)?.lastPathComponent }
}

@Suite(.serialized, .enabled(if: pythonAvailable))
struct InstallEndToEndTests {
    private static let big = "weights/model.safetensors"
    private static let small = "config.json"

    @Test func installsAndPublishesAtomically() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 2 << 20, 1), (Self.small, 10 << 10, 2)])
        try await s.publish()

        let events = await collect(s.downloader(), s.plan)

        #expect(events.first?.phase == .preflight)
        #expect(events.last?.phase == .installed)
        #expect(events.contains { $0.phase == .verifying })
        #expect(events.contains { $0.phase == .moving })
        #expect(events.last?.bytesDone == s.plan.totalBytes)

        #expect(try Data(contentsOf: s.destination.appending(path: Self.big)) == s.payloads[Self.big])
        #expect(try Data(contentsOf: s.destination.appending(path: Self.small)) == s.payloads[Self.small])
        #expect(!FileManager.default.fileExists(atPath: s.staging.path), "staging folder is removed after publish")
        #expect(!fileNames(under: s.destination).contains { $0.hasSuffix(".partial") || $0.hasSuffix(".parts") })
        #expect(ModelDownloader.interruptedInstalls(modelsRoot: s.models.url).isEmpty)

        let stats = try await server.stats()
        let bigRanged = stats.requests.filter { $0.key == s.key(Self.big) && $0.range != nil }
        #expect(bigRanged.count >= 2, "a 2 MiB file uses several connections")
        #expect(stats.requests.allSatisfy { $0.ua == "mlx-create/test" }, "fixed user agent on every request")
        #expect(stats.requests.allSatisfy { $0.cookie == nil }, "the redirect's Set-Cookie is never sent back")
    }

    @Test func resumesAfterCancelWithRangeAndSidecarETag() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 4 << 20, 3)])
        try await s.publish()
        try await server.control(["throttle_ms": 40])
        let downloader = s.downloader()

        let stopped = await interrupt(downloader, s.plan, after: 1 << 20)
        #expect(stopped)
        #expect(ModelDownloader.interruptedInstalls(modelsRoot: s.models.url).map(\.plan) == [s.plan])
        let partial = s.staging.appending(path: "\(Self.big).partial")
        let sidecar = try #require(ResumeSidecar.load(forPartial: partial, size: 4 << 20))
        #expect(sidecar.etag == "\"v1-3\"", "sidecar keeps the post-redirect ETag")
        #expect(sidecar.completedBytes >= 1 << 20)

        try await server.control(["reset_stats": true, "throttle_ms": 0])
        let events = await collect(downloader, s.plan)

        #expect(events.last?.phase == .installed)
        #expect(try Data(contentsOf: s.destination.appending(path: Self.big)) == s.payloads[Self.big])
        let stats = try await server.stats()
        let served = stats.bytesServed[s.key(Self.big)] ?? 0
        #expect(served < 4 << 20, "resume re-requests only the unfinished bytes")
        #expect(
            stats.requests.contains { $0.range != nil && $0.range != "bytes=0-" && $0.status == 206 },
            "resume uses plain Range requests")
    }

    @Test func redirectIsResolvedAgainOnEveryResume() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 2 << 20, 4)])
        try await s.publish()
        try await server.control(["throttle_ms": 40])
        let downloader = s.downloader()

        #expect(await interrupt(downloader, s.plan, after: 1 << 20))

        try await server.control(["expire_cdn": true, "reset_stats": true, "throttle_ms": 0])
        let events = await collect(downloader, s.plan)

        #expect(events.last?.phase == .installed)
        let stats = try await server.stats()
        #expect(
            stats.requests.contains { $0.key == s.key(Self.big) && $0.status == 302 },
            "the resolve URL is requested again")
        #expect(!stats.requests.contains { $0.status == 403 }, "the expired CDN URL is never reused")
    }

    @Test func changedETagDiscardsPartialAndRestarts() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 2 << 20, 5)])
        try await s.publish()
        try await server.control(["throttle_ms": 40])
        let downloader = s.downloader()

        #expect(await interrupt(downloader, s.plan, after: 1 << 20))

        try await s.changeEtag(Self.big)
        try await server.control(["reset_stats": true, "throttle_ms": 0])
        let events = await collect(downloader, s.plan)

        #expect(events.last?.phase == .installed, "the restart completes against the new ETag")
        let stats = try await server.stats()
        #expect((stats.bytesServed[s.key(Self.big)] ?? 0) >= 2 << 20, "the partial was discarded, so the file restarts")
    }

    @Test func hashMismatchDeletesFileAndInstallsNothing() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 300 << 10, 6)])
        try s.overwrite(Self.big, seed: 99)
        try await s.publish()

        let events = await collect(s.downloader(), s.plan)

        #expect(events.contains { $0.phase == .verifying })
        guard case .hashMismatch(let path, let expected, _)? = installError(events) else {
            Issue.record("expected hashMismatch, got \(String(describing: installError(events)))")
            return
        }
        #expect(path == Self.big)
        #expect(expected == s.plan.files[0].sha256)
        #expect(!FileManager.default.fileExists(atPath: s.staging.appending(path: Self.big).path))
        #expect(!FileManager.default.fileExists(atPath: s.staging.appending(path: "\(Self.big).partial").path))
        #expect(!FileManager.default.fileExists(atPath: s.destination.path), "nothing reaches Weights")
    }

    @Test func diskPreflightRefusesBeforeAnyRequest() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 2 << 20, 7)])
        try await s.publish()
        try await server.control(["reset_stats": true])

        let events = await collect(s.downloader(available: 1000), s.plan)

        #expect(installError(events) == .insufficientDisk(needed: s.plan.totalBytes + (1 << 30), available: 1000))
        let description = try #require(installError(events)?.errorDescription)
        #expect(description.contains(Int64(1000).formatted(ByteCountFormatStyle(style: .file))))
        #expect(description.contains((s.plan.totalBytes + (1 << 30)).formatted(ByteCountFormatStyle(style: .file))))
        #expect(try await server.stats().requests.isEmpty)
    }

    @Test func ignoredRangeFallsBackToSingleStream() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 2 << 20, 8)])
        try await s.publish()
        try await server.control(["mode": "ignore-range", "reset_stats": true])

        let events = await collect(s.downloader(), s.plan)

        #expect(events.last?.phase == .installed)
        #expect(try Data(contentsOf: s.destination.appending(path: Self.big)) == s.payloads[Self.big])
        let stats = try await server.stats()
        #expect(stats.requests.contains { $0.range != nil && $0.status == 200 }, "the ranged request was answered in full")
        #expect(stats.requests.contains { $0.range == nil && $0.status == 200 }, "then one plain stream is used")
    }

    @Test func stallIsRetriedFromTheSidecar() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 2 << 20, 9)])
        try await s.publish()
        try await server.control(["stall": ["after_bytes": 65536, "times": 1], "reset_stats": true])

        let events = await collect(s.downloader(stallTimeout: .seconds(1), maxStalls: 3), s.plan)

        #expect(events.last?.phase == .installed)
        #expect(try Data(contentsOf: s.destination.appending(path: Self.big)) == s.payloads[Self.big])
        let stats = try await server.stats()
        #expect(stats.requests.filter { $0.key == s.key(Self.big) }.count >= 5, "4 connections plus the retry")
    }

    @Test func repeatedStallsFailTheInstall() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 2 << 20, 10)])
        try await s.publish()
        try await server.control(["stall": ["after_bytes": 65536, "times": 10]])

        let events = await collect(s.downloader(stallTimeout: .seconds(1), maxStalls: 2), s.plan)

        #expect(installError(events) == .stalled(path: Self.big))
        #expect(!FileManager.default.fileExists(atPath: s.destination.path))
    }

    @Test func symlinkEscapeInStagingIsRejectedBeforeAnyRequest() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [("sub/\(Self.small)", 10 << 10, 11)])
        try await s.publish()
        try await server.control(["reset_stats": true])
        let outside = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: s.staging, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: s.staging.appending(path: "sub"), withDestinationURL: outside.url)

        let events = await collect(s.downloader(), s.plan)

        guard case .pathRejected(let path, _)? = installError(events) else {
            Issue.record("expected pathRejected, got \(String(describing: installError(events)))")
            return
        }
        #expect(path == "sub/\(Self.small)")
        #expect(fileNames(under: outside.url).isEmpty, "nothing is written through the link")
        #expect(try await server.stats().requests.isEmpty)
    }

    @Test func traversalAndAbsolutePathsAreRejectedBeforeAnyRequest() async throws {
        for bad in ["../escape.json", "/abs/escape.json"] {
            let server = try RangeServer()
            let s = try Scenario(server: server, files: [(Self.small, 10 << 10, 12)])
            let plan = InstallPlan(
                modelID: "test/model", repo: "org/model", revision: Scenario.revision,
                files: [.init(path: bad, size: 10 << 10, sha256: s.plan.files[0].sha256)])
            try await s.publish()
            try await server.control(["reset_stats": true])

            let events = await collect(s.downloader(), plan)

            guard case .pathRejected(let path, _)? = installError(events) else {
                Issue.record("\(bad): expected pathRejected, got \(String(describing: installError(events)))")
                continue
            }
            #expect(path == bad)
            #expect(try await server.stats().requests.isEmpty)
        }
    }

    @Test func existingDestinationIsNeverOverwritten() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.small, 10 << 10, 13)])
        try await s.publish()
        try FileManager.default.createDirectory(at: s.destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: s.destination.appending(path: Self.small))

        let events = await collect(s.downloader(), s.plan)

        #expect(installError(events) == .destinationExists(s.destination.path))
        #expect(try Data(contentsOf: s.destination.appending(path: Self.small)) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(atPath: s.staging.path), "destination is checked before staging is created")
    }

    @Test func overlongPartialResponseFailsWithoutWritingPastItsChunk() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.big, 2 << 20, 14)])
        try await s.publish()
        try await server.control(["mode": "overrun-206"])

        let events = await collect(s.downloader(), s.plan)

        guard case .network(let path, _)? = installError(events) else {
            Issue.record("expected network failure, got \(String(describing: installError(events)))")
            return
        }
        #expect(path == Self.big)
        #expect(!FileManager.default.fileExists(atPath: s.destination.path), "nothing reaches Weights")

        let partial = s.staging.appending(path: "\(Self.big).partial")
        let sidecar = try JSONDecoder().decode(
            ResumeSidecar.self, from: Data(contentsOf: ResumeSidecar.sidecarURL(forPartial: partial)))
        let written = try Data(contentsOf: partial)
        let planned = try #require(s.payloads[Self.big])
        for chunk in sidecar.chunks {
            #expect(chunk.done <= chunk.length, "a chunk never banks more bytes than it holds")
            let lower = Int(chunk.start)
            let upper = Int(min(chunk.start + chunk.done, Int64(written.count), Int64(planned.count)))
            guard upper > lower else { continue }
            #expect(written[lower..<upper] == planned[lower..<upper], "neighbouring chunks keep their planned bytes")
        }
    }

    @Test func overlongSingleStreamFailsAtItsPlannedSize() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.small, 300 << 10, 15)])
        try await s.publish()
        try await server.control(["mode": "overrun-200"])

        let events = await collect(s.downloader(), s.plan)

        guard case .network(let path, _)? = installError(events) else {
            Issue.record("expected network failure, got \(String(describing: installError(events)))")
            return
        }
        #expect(path == Self.small)
        #expect(!FileManager.default.fileExists(atPath: s.destination.path), "nothing reaches Weights")
        let partial = s.staging.appending(path: "\(Self.small).partial")
        #expect(try Data(contentsOf: partial) == s.payloads[Self.small], "no byte past the planned size is written")
    }

    @Test func leftoversFromAnOlderPlanNeverReachWeights() async throws {
        let server = try RangeServer()
        let s = try Scenario(server: server, files: [(Self.small, 10 << 10, 16)])
        try await s.publish()
        let stale = s.staging.appending(path: "stale", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 4096).write(to: stale.appending(path: "extra.safetensors.partial"))
        try Data("never verified".utf8).write(to: s.staging.appending(path: "extra.safetensors"))

        let events = await collect(s.downloader(), s.plan)

        #expect(events.last?.phase == .installed)
        #expect(Set(fileNames(under: s.destination)) == [Self.small], "only planned files reach Weights")
        #expect(try Data(contentsOf: s.destination.appending(path: Self.small)) == s.payloads[Self.small])
    }

    /// A cancel that lands while the downloader is still hashing ends the install before the move. Nothing reaches
    /// `Weights/`, the verified file stays in staging, and a later install resumes without fetching it again.
    @Test func cancelWhileVerifyingKeepsStagingAndTheNextInstallResumes() async throws {
        let server = try RangeServer()
        let size = 128 << 20
        let s = try Scenario(server: server, files: [(Self.big, size, 18)])
        try await s.publish()
        let downloader = s.downloader()

        // Hashing 128 MiB takes long enough for the cancel to land before the move check.
        let run = await downloader.install(s.plan)
        var events: [InstallEvent] = []
        for await event in run.events {
            events.append(event)
            if event.phase == .verifying { run.cancel() }
        }

        #expect(events.last?.phase == .cancelled)
        #expect(!events.contains { $0.phase == .moving }, "the move never starts")
        #expect(!FileManager.default.fileExists(atPath: s.destination.path), "nothing reaches Weights")
        #expect(FileManager.default.fileExists(atPath: s.staging.appending(path: "\(Self.big).partial").path))

        try await server.control(["reset_stats": true])
        let resumed = await collect(downloader, s.plan)

        #expect(resumed.last?.phase == .installed)
        #expect(try Data(contentsOf: s.destination.appending(path: Self.big)) == s.payloads[Self.big])
        let stats = try await server.stats()
        #expect((stats.bytesServed[s.key(Self.big)] ?? 0) < Int64(size), "the verified bytes are not fetched again")
    }
}

private func isNetworkError(_ error: Error?) -> Bool {
    if case .network? = error as? InstallError { return true }
    return false
}

/// Response policy, driven directly: no server, no transfer.
@Suite struct AcceptPolicyTests {
    private func attempt(_ models: TemporaryDirectory, size: Int64 = 2 << 20) throws -> FileAttempt {
        let config = ModelDownloader.Configuration(modelsRoot: models.url, userAgent: "test", connections: 4, minChunkBytes: 256 << 10)
        let attempt = FileAttempt(
            file: .init(path: "w.bin", size: size, sha256: String(repeating: "0", count: 64)),
            url: URL(string: "http://127.0.0.1/x")!,
            partial: models.url.appending(path: "w.bin.partial"),
            session: URLSession(configuration: .ephemeral),
            configuration: config,
            progress: InstallProgress(total: size) { _ in },
            singleOnly: false)
        try attempt.prepare()
        return attempt
    }

    private func response(_ status: Int, etag: String? = "\"e\"", range: String? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let etag { headers["ETag"] = etag }
        if let range { headers["Content-Range"] = range }
        return HTTPURLResponse(url: URL(string: "http://127.0.0.1/x")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    private func failure<T>(_ result: Result<T, Error>) -> Error? {
        if case .failure(let error) = result { return error }
        return nil
    }

    @Test func contentRangeTotalThatDisagreesWithCatalogFails() throws {
        let dir = try TemporaryDirectory()
        defer { withExtendedLifetime(dir) {} }
        let a = try attempt(dir)
        let result = a.accept(response(206, range: "bytes 0-524287/2097153"), chunk: 0, ranged: true)
        #expect(failure(result) as? InstallError == .sizeMismatch(path: "w.bin", planned: 2 << 20, server: 2_097_153))
    }

    @Test func rangeStartOtherThanRequestedIsRejected() throws {
        let dir = try TemporaryDirectory()
        defer { withExtendedLifetime(dir) {} }
        let a = try attempt(dir)
        let result = a.accept(response(206, range: "bytes 1-524288/2097152"), chunk: 0, ranged: true)
        #expect(isNetworkError(failure(result)))
    }

    @Test func rangeEndOtherThanPlannedIsRejected() throws {
        let dir = try TemporaryDirectory()
        defer { withExtendedLifetime(dir) {} }
        let a = try attempt(dir)
        let result = a.accept(response(206, range: "bytes 0-524286/2097152"), chunk: 0, ranged: true)
        #expect(isNetworkError(failure(result)))
    }

    @Test func missingETagIsRejected() throws {
        let dir = try TemporaryDirectory()
        defer { withExtendedLifetime(dir) {} }
        let a = try attempt(dir)
        let result = a.accept(response(206, etag: nil, range: "bytes 0-524287/2097152"), chunk: 0, ranged: true)
        #expect(isNetworkError(failure(result)))
    }

    @Test func eTagChangeBetweenChunksIsSourceChanged() throws {
        let dir = try TemporaryDirectory()
        defer { withExtendedLifetime(dir) {} }
        let a = try attempt(dir)
        let first = a.accept(response(206, etag: "\"a\"", range: "bytes 0-524287/2097152"), chunk: 0, ranged: true)
        #expect(failure(first) == nil)
        let second = a.accept(response(206, etag: "\"b\"", range: "bytes 524288-1048575/2097152"), chunk: 1, ranged: true)
        #expect(failure(second) as? FileRetry == .sourceChanged)
    }

    @Test func fullResponseToRangedChunksFallsBackToSingleStream() throws {
        let dir = try TemporaryDirectory()
        defer { withExtendedLifetime(dir) {} }
        let a = try attempt(dir)
        let result = a.accept(response(200), chunk: 0, ranged: true)
        #expect(failure(result) as? FileRetry == .rangeUnsupported)
    }

    @Test func contentRangeParsesStartAndTotal() {
        let r = response(206, range: "bytes 524288-1048575/2097152")
        #expect(FileAttempt.contentRange(r)?.start == 524288)
        #expect(FileAttempt.contentRange(r)?.total == 2_097_152)
        #expect(FileAttempt.contentRange(response(206, range: "bytes */5")) == nil)
    }
}
