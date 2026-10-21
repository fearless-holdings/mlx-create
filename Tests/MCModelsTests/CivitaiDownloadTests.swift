import Foundation
import Testing

@testable import MCModels

private let civitaiPythonAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

/// The Civitai section of the Range server's `/__stats`.
private struct CivitaiLog: Decodable {
    struct Entry: Decodable {
        let path: String
        let host: String?
        let authorization: String?
        let range: String?
        let status: Int
        let bytes: Int64
    }

    let civitaiRequests: [Entry]
}

private func civitaiRequests(_ server: RangeServer) async throws -> [CivitaiLog.Entry] {
    let url = URL(string: "http://127.0.0.1:\(server.port)/__stats")!
    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(CivitaiLog.self, from: data).civitaiRequests
}

/// A safetensors file served by the Range server, with the Civitai mimic configured for one download.
private struct CivitaiFixture {
    static let key = "test-key"

    let server: RangeServer
    let directory: TemporaryDirectory
    let bytes: Data
    let headerLength: UInt64

    var sha256: String { Scenario.sha256Hex(bytes) }
    var staging: URL { directory.url.appending(path: "staging") }
    var partial: URL { staging.appending(path: "42.partial") }
    var downloadURL: URL { URL(string: "http://127.0.0.1:\(server.port)/civitai/download/42")! }

    /// `civitai` overrides the defaults: cross-host redirect, the key above, and no faults.
    static func start(
        tensorBytes: Int = 4096,
        throttleMs: Int = 0,
        civitai overrides: [String: Any] = [:]
    ) async throws -> CivitaiFixture {
        let server = try RangeServer()
        let directory = try TemporaryDirectory()
        let (bytes, headerLength) = safetensors(tensorBytes: tensorBytes)
        let file = directory.url.appending(path: "lora.safetensors")
        try bytes.write(to: file)
        var civitai: [String: Any] = ["file": file.path, "key": key, "redirect": "cross_host"]
        civitai.merge(overrides) { _, new in new }
        try await server.control(["civitai": civitai, "throttle_ms": throttleMs])
        return CivitaiFixture(server: server, directory: directory, bytes: bytes, headerLength: headerLength)
    }

    /// The 8-byte little-endian header length, the JSON header, then the tensor bytes.
    private static func safetensors(tensorBytes: Int) -> (Data, UInt64) {
        let header = Data(#"{"lora_down.weight":{"dtype":"F32","shape":[\#(tensorBytes / 4)],"data_offsets":[0,\#(tensorBytes)]}}"#.utf8)
        var file = withUnsafeBytes(of: UInt64(header.count).littleEndian) { Data($0) }
        file.append(header)
        file.append(Scenario.payload(size: tensorBytes, seed: 7))
        return (file, UInt64(header.count))
    }
}

private func downloader(
    plaintextHosts: Set<String> = ["127.0.0.1", "localhost"],
    available: @escaping @Sendable (URL) throws -> Int64 = { _ in Int64.max / 4 }
) -> CivitaiDownloader {
    CivitaiDownloader(plaintextHosts: plaintextHosts, availableBytes: available)
}

private func request(
    _ fixture: CivitaiFixture,
    key: String? = CivitaiFixture.key,
    advertised: Int64? = nil,
    expected: String? = nil,
    classify: @escaping @Sendable (Data, UInt64) throws -> Void = { _, _ in }
) -> CivitaiDownloadRequest {
    CivitaiDownloadRequest(
        versionID: 42,
        downloadURL: fixture.downloadURL,
        apiHost: "127.0.0.1",
        apiKey: key,
        expectedSHA256: expected ?? fixture.sha256,
        advertisedSize: advertised ?? Int64(fixture.bytes.count),
        classify: classify,
        stagingDirectory: fixture.staging)
}

private func collect(_ run: CivitaiDownloadRun) async -> [CivitaiDownloadEvent] {
    var events: [CivitaiDownloadEvent] = []
    for await event in run.events { events.append(event) }
    return events
}

private func isTerminal(_ phase: CivitaiDownloadEvent.Phase) -> Bool {
    switch phase {
    case .staged, .failed, .cancelled: return true
    default: return false
    }
}

/// The terminal phase, when the stream ends on it and holds exactly one terminal event. Nil otherwise.
private func terminal(_ events: [CivitaiDownloadEvent]) -> CivitaiDownloadEvent.Phase? {
    guard let last = events.last?.phase, isTerminal(last) else { return nil }
    return events.filter { isTerminal($0.phase) }.count == 1 ? last : nil
}

private func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// Records what the classifier was handed.
private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(prefix: Data, total: UInt64)] = []

    func add(_ prefix: Data, _ total: UInt64) {
        lock.withLock { calls.append((prefix, total)) }
    }

    var all: [(prefix: Data, total: UInt64)] { lock.withLock { calls } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock { () -> Int in
            count += 1
            return count
        }
    }
}

private struct Refused: Error, LocalizedError, Sendable {
    var errorDescription: String? { "not a LoRA" }
}

@Suite(.serialized, .enabled(if: civitaiPythonAvailable))
struct CivitaiDownloadTests {
    @Test func stagesVerifiedFileThroughCrossHostRedirect() async throws {
        let fixture = try await CivitaiFixture.start()
        let seen = Recorded()
        let run = await downloader().start(request(fixture, classify: { prefix, total in seen.add(prefix, total) }))
        let events = await collect(run)

        guard case .staged(let result)? = terminal(events) else {
            Issue.record("expected a staged terminal event, got \(events.map(\.phase))")
            return
        }
        #expect(result.sha256 == fixture.sha256)
        #expect(result.byteCount == Int64(fixture.bytes.count))
        #expect(result.stagedURL.path == fixture.partial.path)
        let staged = try Data(contentsOf: result.stagedURL)
        #expect(staged == fixture.bytes)

        #expect(seen.all.count == 1)
        #expect(seen.all.first?.prefix == fixture.bytes.prefix(8 + Int(fixture.headerLength)))
        #expect(seen.all.first?.total == UInt64(fixture.bytes.count))

        // The key reaches the API host only. The hop to localhost carries no Authorization.
        let log = try await civitaiRequests(fixture.server)
        let api = log.filter { $0.path.hasPrefix("/civitai/download") }
        let cdn = log.filter { $0.path.hasPrefix("/civitai-cdn") }
        #expect(!api.isEmpty)
        #expect(api.allSatisfy { $0.authorization == "Bearer \(CivitaiFixture.key)" })
        #expect(!cdn.isEmpty)
        #expect(cdn.allSatisfy { $0.authorization == nil && $0.host?.hasPrefix("localhost") == true })
    }

    @Test func missingKeyIsNeedsKeyAndLeavesNoFile() async throws {
        let fixture = try await CivitaiFixture.start()
        let events = await collect(await downloader().start(request(fixture, key: nil)))

        #expect(terminal(events) == .failed(.needsKey))
        #expect(!fileExists(fixture.partial))
        let log = try await civitaiRequests(fixture.server)
        #expect(!log.contains { $0.path.hasPrefix("/civitai-cdn") })
    }

    @Test func savedKeyStillRefusedIsKeyRefused() async throws {
        let fixture = try await CivitaiFixture.start()
        let events = await collect(await downloader().start(request(fixture, key: "wrong-key")))

        #expect(terminal(events) == .failed(.keyRefused))
        #expect(!fileExists(fixture.partial))
        let log = try await civitaiRequests(fixture.server)
        #expect(log.filter { $0.path.hasPrefix("/civitai/download") }.allSatisfy { $0.authorization == "Bearer wrong-key" })
    }

    @Test func overTheCapIsRefusedBeforeAnyRequest() async throws {
        let fixture = try await CivitaiFixture.start()
        let advertised = CivitaiDownloader.sizeCap + 1
        let events = await collect(await downloader().start(request(fixture, advertised: advertised)))

        #expect(terminal(events) == .failed(.tooLarge(size: advertised, cap: CivitaiDownloader.sizeCap)))
        #expect(try await civitaiRequests(fixture.server).isEmpty)
    }

    @Test func withoutRoomIsRefusedBeforeAnyRequest() async throws {
        let fixture = try await CivitaiFixture.start()
        let events = await collect(await downloader(available: { _ in 1000 }).start(request(fixture)))

        let needed = Int64(fixture.bytes.count) + CivitaiDownloader.headroomBytes
        #expect(terminal(events) == .failed(.insufficientDisk(needed: needed, available: 1000)))
        #expect(try await civitaiRequests(fixture.server).isEmpty)
    }

    @Test func plainHTTPAddressIsRefusedWithoutAllowance() async throws {
        let fixture = try await CivitaiFixture.start()
        let events = await collect(await downloader(plaintextHosts: []).start(request(fixture)))

        #expect(terminal(events) == .failed(.insecureAddress))
        #expect(try await civitaiRequests(fixture.server).isEmpty)
    }

    /// The production redirect rule, with only the loopback allowance injected: a key-bearing request that the server
    /// steers from 127.0.0.1 to plain http on the same host must not continue.
    @Test func sameHostDowngradeOfKeyedRequestIsRefused() async throws {
        let fixture = try await CivitaiFixture.start(civitai: ["redirect": "same_host_http"])
        let events = await collect(await downloader().start(request(fixture)))

        guard case .failed(.redirectRefused)? = terminal(events) else {
            Issue.record("expected redirectRefused, got \(events.map(\.phase))")
            return
        }
        let log = try await civitaiRequests(fixture.server)
        #expect(!log.contains { $0.path.hasPrefix("/civitai-cdn") })
        #expect(!fileExists(fixture.partial))
    }

    /// A refused file costs header bytes only: the prefix and header are range-read, then the classifier throws.
    @Test func classifierRefusalTransfersOnlyHeaderBytes() async throws {
        let fixture = try await CivitaiFixture.start()
        let events = await collect(await downloader().start(request(fixture, classify: { _, _ in throw Refused() })))

        #expect(terminal(events) == .failed(.refusedByClassifier(reason: "not a LoRA")))
        let log = try await civitaiRequests(fixture.server)
        let cdn = log.filter { $0.path.hasPrefix("/civitai-cdn") }
        #expect(!cdn.isEmpty)
        #expect(cdn.allSatisfy { $0.range != nil })
        #expect(cdn.reduce(Int64(0)) { $0 + $1.bytes } == 8 + Int64(fixture.headerLength))
        #expect(!fileExists(fixture.partial))
    }

    @Test func ignoredRangeFallsBackToBoundedRead() async throws {
        let fixture = try await CivitaiFixture.start(civitai: ["ignore_range": true])
        let seen = Recorded()
        let events = await collect(
            await downloader().start(
                request(
                    fixture,
                    classify: { prefix, total in
                        seen.add(prefix, total)
                    })))

        guard case .staged(let result)? = terminal(events) else {
            Issue.record("expected a staged terminal event, got \(events.map(\.phase))")
            return
        }
        #expect(result.sha256 == fixture.sha256)
        #expect(try Data(contentsOf: result.stagedURL) == fixture.bytes)
        #expect(seen.all.first?.prefix == fixture.bytes.prefix(8 + Int(fixture.headerLength)))
    }

    @Test func overSendFailsAndRemovesPartial() async throws {
        let fixture = try await CivitaiFixture.start(civitai: ["stream_mode": "overrun"])
        let events = await collect(await downloader().start(request(fixture)))

        #expect(terminal(events) == .failed(.overrun(advertised: Int64(fixture.bytes.count))))
        #expect(!fileExists(fixture.partial))
    }

    /// The mimic stops 1000 bytes early (`SHORT_BY` in range_server.py).
    @Test func shortResponseFailsWithSizeMismatch() async throws {
        let fixture = try await CivitaiFixture.start(civitai: ["stream_mode": "short"])
        let events = await collect(await downloader().start(request(fixture)))

        let advertised = Int64(fixture.bytes.count)
        #expect(terminal(events) == .failed(.sizeMismatch(advertised: advertised, server: advertised - 1000)))
        #expect(!fileExists(fixture.partial))
    }

    @Test func serverSizeDisagreeingWithAdvertisedFailsBeforeStreaming() async throws {
        let fixture = try await CivitaiFixture.start()
        let advertised = Int64(fixture.bytes.count) + 1
        let events = await collect(await downloader().start(request(fixture, advertised: advertised)))

        #expect(terminal(events) == .failed(.sizeMismatch(advertised: advertised, server: Int64(fixture.bytes.count))))
        let log = try await civitaiRequests(fixture.server)
        #expect(!log.contains { $0.path.hasPrefix("/civitai-cdn") && $0.range == nil })
        #expect(!fileExists(fixture.partial))
    }

    @Test func wrongHashDeletesStagedFile() async throws {
        let fixture = try await CivitaiFixture.start()
        let wrong = String(repeating: "0", count: 64)
        let events = await collect(await downloader().start(request(fixture, expected: wrong)))

        #expect(terminal(events) == .failed(.hashMismatch(expected: wrong, actual: fixture.sha256)))
        #expect(!fileExists(fixture.partial))
    }

    /// The signed URL expires once between the header read and the stream: the run re-resolves and succeeds.
    @Test func streamExpiryReResolvesOnce() async throws {
        let fixture = try await CivitaiFixture.start(civitai: ["stream_403": 1])
        let events = await collect(await downloader().start(request(fixture)))

        guard case .staged(let result)? = terminal(events) else {
            Issue.record("expected a staged terminal event, got \(events.map(\.phase))")
            return
        }
        #expect(try Data(contentsOf: result.stagedURL) == fixture.bytes)
        let log = try await civitaiRequests(fixture.server)
        let streams = log.filter { $0.path.hasPrefix("/civitai-cdn") && $0.range == nil }
        #expect(streams.map(\.status) == [403, 200])
    }

    @Test func secondStreamExpiryFailsPlainly() async throws {
        let fixture = try await CivitaiFixture.start(civitai: ["stream_403": 2])
        let events = await collect(await downloader().start(request(fixture)))

        #expect(terminal(events) == .failed(.signedURLExpired))
        #expect(!fileExists(fixture.partial))
        let log = try await civitaiRequests(fixture.server)
        let streams = log.filter { $0.path.hasPrefix("/civitai-cdn") && $0.range == nil }
        #expect(streams.map(\.status) == [403, 403])
    }

    /// Free space drops after the first chunk. The re-check during transfer stops the write and removes the partial.
    @Test func diskDropDuringTransferStopsAndRemovesPartial() async throws {
        let fixture = try await CivitaiFixture.start()
        let calls = Counter()
        let run = await downloader(available: { _ in calls.next() == 1 ? Int64.max / 4 : 0 }).start(request(fixture))
        let events = await collect(run)

        guard case .failed(.insufficientDisk(_, let available))? = terminal(events) else {
            Issue.record("expected insufficientDisk, got \(events.map(\.phase))")
            return
        }
        #expect(available == 0)
        #expect(!fileExists(fixture.partial))
    }

    @Test func cancelRemovesPartialAndReportsCancelled() async throws {
        let fixture = try await CivitaiFixture.start(tensorBytes: 8 << 20, throttleMs: 20)
        let run = await downloader().start(request(fixture))
        var events: [CivitaiDownloadEvent] = []
        var requested = false
        for await event in run.events {
            events.append(event)
            if !requested, case .downloading = event.phase {
                requested = true
                run.cancel()
            }
        }

        #expect(terminal(events) == .cancelled)
        #expect(!fileExists(fixture.partial))
    }
}

/// Policy rules that need no server: the production https rule, the loopback allowance, and key handling on redirects.
@Suite struct CivitaiTransportPolicyTests {
    @Test func plainHTTPStaysOffTheAllowance() throws {
        let production = CivitaiTransportPolicy(apiHost: "civitai.com")
        #expect(production.accepts(try #require(URL(string: "https://civitai.com/api/download/models/1"))))
        #expect(!production.accepts(try #require(URL(string: "http://civitai.com/api/download/models/1"))))
        #expect(!production.accepts(try #require(URL(string: "http://127.0.0.1/x"))))

        // The loopback allowance does not open other hosts over plain http.
        let loopback = CivitaiTransportPolicy(apiHost: "127.0.0.1", plaintextHosts: ["127.0.0.1"])
        #expect(loopback.accepts(try #require(URL(string: "http://127.0.0.1:9/x"))))
        #expect(!loopback.accepts(try #require(URL(string: "http://example.com/x"))))
        #expect(loopback.accepts(try #require(URL(string: "https://example.com/x"))))
    }

    @Test func keyNeverFollowsAHostChangeAndNeverStepsDownToHTTP() throws {
        let production = CivitaiTransportPolicy(apiHost: "civitai.com")
        let from = try #require(URL(string: "https://civitai.com/api/download/models/1"))
        let elsewhere = try #require(URL(string: "https://b2.example.com/file?sig=1"))
        #expect(production.redirect(from: from, to: elsewhere, carriesKey: true) == .follow(keepKey: false))

        let sameHost = try #require(URL(string: "https://civitai.com/api/download/models/2"))
        #expect(production.redirect(from: from, to: sameHost, carriesKey: true) == .follow(keepKey: true))

        let local = CivitaiTransportPolicy(apiHost: "127.0.0.1", plaintextHosts: ["127.0.0.1"])
        let localFrom = try #require(URL(string: "http://127.0.0.1:9/a"))
        let localTo = try #require(URL(string: "http://127.0.0.1:9/b"))
        #expect(
            local.redirect(from: localFrom, to: localTo, carriesKey: true)
                == .refuse(reason: "the server redirected the key-bearing request to plain http"))
    }

    @Test func keyGoesOnlyToTheHTTPSAPIHostOnTheDefaultPort() throws {
        let production = CivitaiTransportPolicy(apiHost: "civitai.com")
        let cases: [(url: String, sends: Bool)] = [
            ("https://civitai.com/api/v1/models", true),
            ("https://CIVITAI.com/api/v1/models", true),
            ("http://civitai.com/api/v1/models", false),
            ("https://civitai.com:8443/api/v1/models", false),
            ("https://b2.civitai.com/signed/file.safetensors", false),
            ("https://image.civitai.com/preview.jpeg", false),
            ("https://civitai.com.example.net/api/v1/models", false),
            ("https://localhost/api/v1/models", false),
        ]
        for entry in cases {
            let url = try #require(URL(string: entry.url))
            #expect(production.sendsKey(to: url) == entry.sends, "\(entry.url)")
        }
    }
}

/// Scripted header replies for the downloader: each open returns the next reply, and running out throws.
private final class ScriptedFileTransport: CivitaiFileTransport, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var opened = 0

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    var openCount: Int { lock.withLock { opened } }

    func open(_ request: CivitaiFileRequest) async throws -> CivitaiFileResponse {
        let reply: Reply? = lock.withLock {
            opened += 1
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let reply else { throw URLError(.badServerResponse) }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        if !reply.body.isEmpty { continuation.yield(reply.body) }
        continuation.finish()
        return CivitaiFileResponse(
            status: reply.status, headers: reply.headers, url: request.url, body: stream, cancel: {})
    }
}

@Suite struct CivitaiDownloadStatusTests {
    private func run(
        _ replies: [ScriptedFileTransport.Reply],
        key: String? = nil
    ) async throws -> (events: [CivitaiDownloadEvent], transport: ScriptedFileTransport) {
        let directory = try TemporaryDirectory()
        let transport = ScriptedFileTransport(replies)
        let downloader = CivitaiDownloader(transport: transport, plaintextHosts: [], availableBytes: { _ in Int64.max / 4 })
        let request = CivitaiDownloadRequest(
            versionID: 42,
            downloadURL: try #require(URL(string: "https://civitai.com/api/download/models/42")),
            apiHost: "civitai.com",
            apiKey: key,
            expectedSHA256: String(repeating: "0", count: 64),
            advertisedSize: 10,
            classify: { _, _ in },
            stagingDirectory: directory.url.appending(path: "staging"))
        let events = await collect(await downloader.start(request))
        return (events, transport)
    }

    private func status(_ code: Int, headers: [String: String] = [:]) -> ScriptedFileTransport.Reply {
        .init(status: code, headers: headers, body: Data())
    }

    @Test func notFoundIsNotFound() async throws {
        let (events, _) = try await run([status(404)])
        #expect(terminal(events) == .failed(.notFound))
    }

    @Test func tooManyRequestsCarriesRetryAfter() async throws {
        let (events, _) = try await run([status(429, headers: ["retry-after": "120"])])
        #expect(terminal(events) == .failed(.rateLimited(retryAfter: "120")))
    }

    @Test func regionLimitedIsRegionLimited() async throws {
        let (events, _) = try await run([status(451)])
        #expect(terminal(events) == .failed(.regionLimited))
    }

    /// A 403 on the API address during the header-tail read is a refused request, not an expired signed URL, so it
    /// is never re-resolved.
    @Test func forbiddenOnTheAPIHopIsNotAnExpiredSignedURL() async throws {
        let header = Data([2, 0, 0, 0, 0, 0, 0, 0])
        let head = ScriptedFileTransport.Reply(
            status: 206, headers: ["content-range": "bytes 0-7/10"], body: header)
        let (events, transport) = try await run([head, status(403)])

        #expect(terminal(events) == .failed(.needsKey))
        #expect(transport.openCount == 2)
    }

    @Test func forbiddenWithSavedKeyIsKeyRefused() async throws {
        let (events, _) = try await run([status(403)], key: "saved-key")
        #expect(terminal(events) == .failed(.keyRefused))
    }
}
