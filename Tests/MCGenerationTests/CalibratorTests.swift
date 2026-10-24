import Foundation
import MCCatalog
import MCEngine
import MCGeneration
import Testing

/// A stub engine for calibration runs. Loads of `heldLoad` keep their reply open until the test finishes them,
/// the first `refusals` loads answer out-of-memory, and the first render waits `firstRenderDelay` seconds.
private final class CalibrationEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Set<String>
    private let known: [String]
    private var refusalsLeft: Int
    private let heldLoad: String?
    private let firstRenderDelay: TimeInterval
    private let streamSteps: Int
    private var generations = 0
    private var calls: [String] = []

    init(
        loaded: Set<String>,
        known: [String],
        refusals: Int = 0,
        heldLoad: String? = nil,
        firstRenderDelay: TimeInterval = 0,
        streamSteps: Int = 4
    ) {
        self.loaded = loaded
        self.known = known
        self.refusalsLeft = refusals
        self.heldLoad = heldLoad
        self.firstRenderDelay = firstRenderDelay
        self.streamSteps = streamSteps
    }

    /// Load, unload and generation calls in the order the engine received them.
    var callLog: [String] { lock.withLock { calls } }

    func handle(_ request: EngineStubProtocol.Recorded) -> EngineStubProtocol.Reply {
        switch request.path {
        case "v1/models":
            return .json(modelsJSON())
        case "v1/load-model":
            return handleLoad(Self.modelID(request.body))
        case "v1/unload-model":
            let id = Self.modelID(request.body)
            lock.withLock {
                calls.append("unload \(id)")
                loaded.remove(id)
            }
            return .json("{}")
        case "v1/images/generations":
            let number = lock.withLock { () -> Int in
                calls.append("generate")
                generations += 1
                return generations
            }
            if number == 1, firstRenderDelay > 0 {
                Thread.sleep(forTimeInterval: firstRenderDelay)
            }
            let body = PNGFixture.sseReply(images: 1, width: 768, height: 512, steps: streamSteps)
            return EngineStubProtocol.Reply(status: 200, body: body, tail: nil)
        default:
            return EngineStubProtocol.Reply(status: 404, body: Data(), tail: nil)
        }
    }

    private func handleLoad(_ id: String) -> EngineStubProtocol.Reply {
        let refused = lock.withLock { () -> Bool in
            calls.append("load \(id)")
            if refusalsLeft > 0 {
                refusalsLeft -= 1
                return true
            }
            loaded.insert(id)
            return false
        }
        if refused {
            return EngineStubProtocol.Reply(status: 503, body: PNGFixture.oomBody(), tail: nil)
        }
        if id == heldLoad {
            return EngineStubProtocol.Reply(status: 200, body: Data("{}".utf8), tail: Data())
        }
        return .json("{}")
    }

    private func modelsJSON() -> String {
        let entries = lock.withLock {
            known.map { id in
                #"{"id":"\#(id)","loaded":\#(loaded.contains(id)),"state":"ready","capabilities":["image"],"meta":{"architecture":"test_arch"}}"#
            }
        }
        return #"{"object":"list","data":[\#(entries.joined(separator: ","))]}"#
    }

    private static func modelID(_ body: String) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        return object?["model"] as? String ?? ""
    }
}

private let calibrationModel = "test/calibration-target-4bit"
private let calibrationOther = "test/calibration-other-4bit"
private let calibrationEnhancer = "test/calibration-enhancer-4bit"

private func calibrationFamily(stepsAreFixed: Bool) -> ModelFamily {
    ModelFamily(
        id: "test-calibration-family",
        displayName: "Calibration test family",
        architectures: ["test_arch"],
        sizeGrid: SizeGrid(multiple: 16, min: 256, max: 2048),
        sizePresets: [ImageSize(width: 1024, height: 1024)],
        defaultSize: ImageSize(width: 768, height: 512),
        steps: StepsCapability(defaultSteps: stepsAreFixed ? 8 : 4, min: 1, max: 100),
        guidance: nil,
        supportsNegativePrompt: false,
        stepsAreFixed: stepsAreFixed)
}

private func calibrationTarget(stepsAreFixed: Bool = false) -> CalibrationTarget {
    CalibrationTarget(
        modelID: calibrationModel,
        family: calibrationFamily(stepsAreFixed: stepsAreFixed),
        reference: ReferenceTiming(width: 768, height: 512, steps: 4, seconds: 10))
}

private func calibrationClient(_ endpoint: EngineEndpoint) -> EngineClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [EngineStubProtocol.self]
    return EngineClient(endpoint: { endpoint }, configuration: configuration)
}

private func jsonObject(_ body: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) ?? [:]
}

private func generationRequests(_ endpoint: EngineEndpoint) -> [EngineStubProtocol.Recorded] {
    EngineStubProtocol.requests(endpoint).filter { $0.path == "v1/images/generations" }
}

private func loadCount(_ log: [String]) -> Int {
    log.filter { $0.hasPrefix("load ") }.count
}

struct CalibratorTests {
    @Test func unloadsEveryResidentModelBeforeTheSingleLoad() async throws {
        let engine = CalibrationEngine(
            loaded: [calibrationEnhancer, calibrationOther],
            known: [calibrationEnhancer, calibrationOther, calibrationModel])
        let endpoint = EngineStubProtocol.register(handler: { engine.handle($0) })

        _ = try await Calibrator.measure(
            client: calibrationClient(endpoint), target: calibrationTarget(), retryDelay: .milliseconds(1))

        let log = engine.callLog
        #expect(Set(log.prefix(2)) == ["unload \(calibrationEnhancer)", "unload \(calibrationOther)"])
        #expect(log[2] == "load \(calibrationModel)")
        #expect(loadCount(log) == 1)
        #expect(log.dropFirst(3).allSatisfy { $0 == "generate" })
    }

    @Test func rendersTwiceWithTheFixedRequestAndReturnsTheSecond() async throws {
        let engine = CalibrationEngine(loaded: [], known: [calibrationModel])
        let endpoint = EngineStubProtocol.register(handler: { engine.handle($0) })

        let measurement = try await Calibrator.measure(
            client: calibrationClient(endpoint), target: calibrationTarget(), retryDelay: .milliseconds(1))

        let requests = generationRequests(endpoint)
        #expect(requests.count == 2)
        for request in requests {
            let body = jsonObject(request.body)
            #expect(body["prompt"] as? String == Calibrator.prompt)
            #expect(body["size"] as? String == "768x512")
            #expect(body["steps"] as? Int == 4)
            #expect(body["lora_paths"] == nil)
            #expect(body["lora_scales"] == nil)
            #expect(body["guidance_scale"] == nil)
            #expect(body["negative_prompt"] == nil)
            #expect((body["seed"] as? NSNumber)?.uint32Value == Calibrator.seed)
        }
        #expect(measurement.modelID == calibrationModel)
        #expect(measurement.width == 768)
        #expect(measurement.height == 512)
        #expect(measurement.steps == 4)
    }

    @Test func fixedStepFamilyOmitsStepsAndReportsTheStreamTotal() async throws {
        let engine = CalibrationEngine(loaded: [], known: [calibrationModel], streamSteps: 8)
        let endpoint = EngineStubProtocol.register(handler: { engine.handle($0) })

        let measurement = try await Calibrator.measure(
            client: calibrationClient(endpoint),
            target: calibrationTarget(stepsAreFixed: true),
            retryDelay: .milliseconds(1))

        let requests = generationRequests(endpoint)
        #expect(requests.count == 2)
        for request in requests {
            #expect(jsonObject(request.body)["steps"] == nil)
        }
        #expect(measurement.steps == 8)
    }

    @Test func returnsTheSecondRenderNotTheSlowerFirst() async throws {
        let engine = CalibrationEngine(loaded: [], known: [calibrationModel], firstRenderDelay: 0.6)
        let endpoint = EngineStubProtocol.register(handler: { engine.handle($0) })

        let measurement = try await Calibrator.measure(
            client: calibrationClient(endpoint), target: calibrationTarget(), retryDelay: .milliseconds(1))

        #expect(measurement.seconds < 0.3)
    }

    @Test func loadTimeIsExcludedFromTheMeasurement() async throws {
        let engine = CalibrationEngine(loaded: [], known: [calibrationModel], heldLoad: calibrationModel)
        let endpoint = EngineStubProtocol.register(handler: { engine.handle($0) })
        let client = calibrationClient(endpoint)
        let target = calibrationTarget()

        let task = Task {
            try await Calibrator.measure(client: client, target: target, retryDelay: .milliseconds(1))
        }
        try await eventually { EngineStubProtocol.requests(endpoint).contains { $0.path == "v1/load-model" } }
        try await Task.sleep(for: .milliseconds(600))
        EngineStubProtocol.finishHeld(endpoint)
        let measurement = try await task.value

        #expect(measurement.seconds < 0.3)
    }

    @Test func retriesOutOfMemoryLoadsThenMeasures() async throws {
        let engine = CalibrationEngine(loaded: [], known: [calibrationModel], refusals: 2)
        let endpoint = EngineStubProtocol.register(handler: { engine.handle($0) })

        let measurement = try await Calibrator.measure(
            client: calibrationClient(endpoint), target: calibrationTarget(), retryDelay: .milliseconds(1))

        #expect(loadCount(engine.callLog) == 3)
        #expect(generationRequests(endpoint).count == 2)
        #expect(measurement.modelID == calibrationModel)
    }

    @Test func outOfMemoryThreeTimesThrowsAndRendersNothing() async throws {
        let engine = CalibrationEngine(loaded: [], known: [calibrationModel], refusals: 3)
        let endpoint = EngineStubProtocol.register(handler: { engine.handle($0) })

        do {
            _ = try await Calibrator.measure(
                client: calibrationClient(endpoint), target: calibrationTarget(), retryDelay: .milliseconds(1))
            Issue.record("expected the out-of-memory refusal to propagate")
        } catch EngineError.outOfMemory(engineMessage: _) {
        }

        #expect(loadCount(engine.callLog) == 3)
        #expect(generationRequests(endpoint).isEmpty)
    }
}
