import Foundation
import MCCatalog
import MCEngine
import Testing

@testable import MCEngine

/// The plumbing the three image suites share (plan U4): the families under test, the request `GenerationComposer` and
/// `Executor` would send for them, the PNG's own header, one raw SSE capture, and the record-one-probe wrapper.
enum ImageContract {
    /// A bundled family with the engine id of the model that carries it.
    struct Target: Sendable {
        let family: ModelFamily
        let modelID: String
    }

    /// The prompt every image probe sends.
    static let prompt = "a calm lake at dawn, soft light on still water"

    /// The negative prompt a draft carries on a family that supports one. No shipped record supports one.
    static let composedNegativePrompt = "blurry, low quality, watermark"

    /// Every bundled family with its installed model, in registry order. A family without a model throws, so the run
    /// stays incomplete instead of green (R8).
    static func targets(_ engine: ContractEngine) async throws -> [Target] {
        let models = try await engine.installedImageModels()
        return try ContractModels.registry().families.map { family in
            Target(family: family, modelID: try ContractModels.model(for: family, in: models).id)
        }
    }

    /// The family's smallest offered size, so one suite fits every family.
    static func smallestSize(of family: ModelFamily) throws -> ImageSize {
        guard let size = family.sizePresets.min(by: { $0.width * $0.height < $1.width * $1.height }) else {
            throw ContractHarnessError.missing("a size preset for family \(family.id)")
        }
        return size
    }

    /// What the probes send for `steps`: none on a fixed-step family (the checkpoint's own count runs), the record's
    /// default otherwise. `GenerationComposer` sends none until the user changes the count; a probe states it, so the
    /// count under test is the record's and not an engine default the record does not mention.
    static func steps(for family: ModelFamily) -> Int? {
        family.stepsAreFixed ? nil : family.steps.defaultSteps
    }

    /// The request one job carries, composed as `GenerationComposer.enqueue` and `Executor.generateNext` compose it:
    /// the family record decides the negative prompt and the guidance, the caller passes an already-normalized size,
    /// and the seed is always explicit.
    static func request(for target: Target, size: ImageSize, steps: Int?, seed: UInt32) -> ImageRequest {
        ImageRequest(
            model: target.modelID,
            prompt: prompt,
            negativePrompt: target.family.supportsNegativePrompt ? composedNegativePrompt : nil,
            width: size.width,
            height: size.height,
            steps: steps,
            guidance: target.family.guidance?.defaultValue,
            seed: seed)
    }

    /// Makes the target's model resident, as `Executor.switchModel` does: unload every other resident model, then load.
    static func makeResident(_ target: Target, on engine: ContractEngine) async throws {
        let resident = try await engine.client.models().filter(\.loaded).map(\.id)
        guard !resident.contains(target.modelID) else { return }
        for other in resident { try await engine.client.unload(model: other) }
        try await engine.client.load(model: target.modelID)
    }

    /// One generation through the app's client: its events in arrival order and the PNG its complete frame carries.
    struct ClientRun {
        let events: [GenEvent]
        let png: Data
    }

    static func generate(_ request: ImageRequest, on engine: ContractEngine) async throws -> ClientRun {
        var events: [GenEvent] = []
        var png: Data?
        for try await event in engine.client.generateImage(request) {
            events.append(event)
            if case .completed(let data) = event { png = data }
        }
        guard let png else { throw EngineError.streamEndedWithoutComplete }
        return ClientRun(events: events, png: png)
    }

    /// The `(step, total)` of every progress event, in arrival order.
    static func progress(_ events: [GenEvent]) -> [(step: Int, total: Int)] {
        events.compactMap { event in
            guard case .progress(let step, let total, _) = event else { return nil }
            return (step: step, total: total)
        }
    }

    /// One raw `POST /v1/images/generations` answer: every `data:` frame's `type` in arrival order, the events the
    /// app's own parser reads from it, and the PNGs the complete frames carry. Raw HTTP is the only way for the frame
    /// types: a `preview` frame is a type `SSELineParser` ignores, so `GenEvent` alone cannot say whether one arrived.
    struct StreamCapture {
        let frameTypes: [String]
        let events: [GenEvent]
        let images: [Data]
    }

    static func stream(_ request: ImageRequest, on engine: ContractEngine) async throws -> StreamCapture {
        let body = try request.body()
        guard let object = (try JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw ContractHarnessError.missing("a JSON object body for model \(request.model)")
        }
        let response = try await RawHTTP.send(
            "POST", "v1/images/generations", to: engine.endpoint, key: engine.endpoint.apiKey, json: object)
        guard response.status == 200 else {
            throw EngineError.fromResponse(status: response.status, body: response.body)
        }
        var frameTypes: [String] = []
        var events: [GenEvent] = []
        for line in response.text.split(whereSeparator: \.isNewline) {
            if let type = frameType(of: line) { frameTypes.append(type) }
            switch SSELineParser.parse(line: String(line)) {
            case .event(let event): events.append(event)
            case .failed(let error): throw error
            case .ignored: continue
            }
        }
        let images = events.compactMap { event -> Data? in
            guard case .completed(let png) = event else { return nil }
            return png
        }
        return StreamCapture(frameTypes: frameTypes, events: events, images: images)
    }

    /// The `type` of one `data:` frame, read from its own JSON. Nil for lines that carry no JSON frame.
    private static func frameType(of line: Substring) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).drop(while: { $0 == " " })
        guard payload != "[DONE]" else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else {
            return nil
        }
        return object["type"] as? String
    }

    /// The PNG signature check and the IHDR dimensions, read from the chunk itself.
    static func pngSize(_ data: Data) -> ImageSize? {
        let bytes = [UInt8](data)
        guard bytes.count >= 24, Array(bytes[0..<8]) == pngSignature, Array(bytes[12..<16]) == pngIHDR else { return nil }
        return ImageSize(width: Int(bigEndian32(bytes, 16)), height: Int(bigEndian32(bytes, 20)))
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let pngIHDR = Array("IHDR".utf8)

    private static func bigEndian32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    /// `"512x512"`, or `"unreadable"` when the bytes were not a PNG, for probe messages.
    static func describe(_ size: ImageSize?) -> String {
        guard let size else { return "unreadable" }
        return "\(size.width)x\(size.height)"
    }

    /// Writes one family's capture under `NSTemporaryDirectory()/mlxc-contract-captures/<engine version>/`, so a drift
    /// is diffable and nothing a capture writes lands in the repository.
    static func saveCapture(_ capture: StreamCapture, family: ModelFamily, engineVersion: String) throws {
        let directory = try captureDirectory(engineVersion: engineVersion)
        var summary = "types: " + capture.frameTypes.joined(separator: ",") + "\n"
        for event in capture.events {
            switch event {
            case .progress(let step, let total, let stage):
                summary += "progress step=\(step) total=\(total) stage=\(stage)\n"
            case .completed(let png):
                summary += "complete bytes=\(png.count) size=\(describe(pngSize(png)))\n"
            }
        }
        try summary.write(to: directory.appending(path: "\(family.id)-stream.txt"), atomically: true, encoding: .utf8)
        if let png = capture.images.first {
            try png.write(to: directory.appending(path: "\(family.id)-stream.png"))
        }
    }

    private static func captureDirectory(engineVersion: String) throws -> URL {
        let version = engineVersion.replacingOccurrences(of: "/", with: "-")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "mlxc-contract-captures", directoryHint: .isDirectory)
            .appending(path: version, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Records one family probe in the run's ledger. A failure in one family leaves the others recorded, because
    /// `runProbe` records it before rethrowing; a cancelled test still stops the suite. `sourceLocation` keeps every
    /// probe issue pointing at the call in the suite, not at this helper.
    static func record(
        _ probe: FamilyProbe, for target: Target, sourceLocation: SourceLocation = #_sourceLocation,
        _ body: (inout ProbeCheck) async throws -> Void
    ) async throws {
        do {
            try await runProbe(
                probe.id(for: target.family), ledger: ContractRun.ledger, sourceLocation: sourceLocation, body)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return
        }
    }
}

/// `image.stream-shape.<family>` for every bundled family (plan U4, R2). One engine for the suite at the app's 16 GiB
/// single-slot tier, the one the enhancer lease's path uses; the engine swaps the family's model in and out.
///
/// The probe reads one raw SSE body and feeds every line through `SSELineParser`, because two of its invariants cannot
/// be seen through `EngineClient`: a `preview` frame is a type the parser ignores, and the client returns at the first
/// complete event so it cannot say a second never arrived. The client's own stream path is proven by the sibling probes
/// in this suite group (`image.dimensions`, `image.default-steps`, `image.seed-determinism`, `image.cancel-recovers`).
@Suite(.serialized, .enabled(if: ContractEnvironment.enabled))
struct ImageStreamContractTests {
    @Test func everyFamilyStreamsProgressThenOnePngAndNoPreviewFrames() async throws {
        let version = try engineVersion(of: ContractEnvironment.engineBinary)
        try await ContractEngine.run(tier: ContractEngine.singleSlot) { engine in
            for target in try await ImageContract.targets(engine) {
                let family = target.family
                try await ImageContract.record(.imageStreamShape, for: target) { check in
                    try await ImageContract.makeResident(target, on: engine)
                    let request = ImageContract.request(
                        for: target, size: try ImageContract.smallestSize(of: family),
                        steps: ImageContract.steps(for: family), seed: 4242)
                    let capture = try await ImageContract.stream(request, on: engine)

                    let progress = ImageContract.progress(capture.events)
                    check.expect(!progress.isEmpty, "no progress event arrived")
                    check.expect(progress.allSatisfy { $0.total > 0 }, "a progress event carried total 0")
                    let outOfRange = progress.filter { $0.step < 0 || $0.step > $0.total }
                    check.expect(outOfRange.isEmpty, "progress events carried a step outside their total: \(outOfRange)")
                    check.expect(
                        zip(progress, progress.dropFirst()).allSatisfy { $0.0.step <= $0.1.step },
                        "step went backwards: \(progress.map { $0.step })")

                    check.expect(!capture.frameTypes.contains("preview"), "a preview frame arrived")
                    let unknown = capture.frameTypes.filter { $0 != "progress" && $0 != "complete" }
                    check.expect(unknown.isEmpty, "the stream carried frame types no probe knows: \(unknown)")
                    let completes = capture.frameTypes.filter { $0 == "complete" }.count
                    check.expect(completes == 1, "\(completes) complete frames arrived, not one")
                    check.expect(capture.images.count == 1, "\(capture.images.count) complete events carried image data")
                    if let png = capture.images.first {
                        let size = ImageContract.pngSize(png)
                        check.expect(size != nil, "the complete frame is not a PNG (signature or IHDR missing)")
                        check.expect(
                            size.map { $0.width > 0 && $0.height > 0 } ?? false,
                            "the IHDR reads \(ImageContract.describe(size))")
                    }

                    try ImageContract.saveCapture(capture, family: family, engineVersion: version)
                }
            }
        }
    }
}
