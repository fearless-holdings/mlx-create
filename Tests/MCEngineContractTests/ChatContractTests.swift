import Foundation
import MCCatalog
import MCEngine
import MCEnhancer
import Testing

@testable import MCEngine

/// Chat probes for R4 (`docs/lld/engine-contract.md` §4). The request is the one `PromptEnhancer` builds, so the
/// engine is asked exactly what the enhancer asks: plain text, `enable_thinking` false, no JSON schema.
@Suite(.serialized, .enabled(if: ContractEnvironment.enabled))
struct ChatContractTests {
    /// `chat.stream-shape`: a real enhancer stream decodes through the app's parser, carries content, finishes with
    /// `stop`, and ends with `[DONE]`.
    @Test func aRealEnhancerStreamDecodesThroughTheParserAndEndsWithDone() async throws {
        try await ContractEngine.run { engine in
            try await runProbe(ContractProbe.chatStreamShape.rawValue, ledger: ContractRun.ledger) { check in
                let request = try await Self.loadEnhancer(on: engine)
                let response = try await Self.postEnhancerRequest(request, to: engine.endpoint, key: engine.endpoint.apiKey)
                check.expect(response.status == 200, "a chat request with the enhancer's body answered \(response.status)")

                var steps = Self.frames(of: response.text)
                guard let last = steps.last else {
                    check.expect(false, "the chat stream carried no data line")
                    return
                }
                check.expect(last == "[DONE]", "the last data line is `\(last)`, not `[DONE]`")
                steps.removeLast()

                var content = ""
                var finished = false
                var doneFrames = 0
                for frame in steps {
                    switch ChatStreamParser.parse(line: "data: \(frame)") {
                    case .delta(let text, let finishes):
                        if let text { content += text }
                        if finishes { finished = true }
                    case .done:
                        doneFrames += 1
                    case .ignored:
                        // A usage-only frame has an empty `choices`, as OpenAI's does.
                        continue
                    case .failed(let error):
                        check.expect(false, "the app's parser rejected a frame: \(error)")
                    }
                }
                check.expect(!content.isEmpty, "no content delta arrived, so the enhancer would show nothing")
                check.expect(finished, "no frame carried a finish_reason, so `streamChat` would throw streamEndedWithoutComplete")
                check.expect(doneFrames == 0, "\(doneFrames) frames before the end were a bare [DONE]")
                let reasons = Self.finishReasons(of: response.text)
                check.expect(!reasons.isEmpty, "no frame carried a finish_reason")
                check.expect(reasons.allSatisfy { $0 == "stop" }, "the stream's finish reasons were \(reasons), not all stop")
            }
        }
    }

    /// `chat.no-thinking-text`: with `enable_thinking` false no reasoning text reaches the content.
    @Test func thinkingOffSendsNoReasoningText() async throws {
        try await ContractEngine.run { engine in
            try await runProbe(ContractProbe.chatNoThinkingText.rawValue, ledger: ContractRun.ledger) { check in
                let request = try await Self.loadEnhancer(on: engine)
                // The app's request always carries `enable_thinking: false` (ChatRequest.body()).
                let response = try await Self.postEnhancerRequest(request, to: engine.endpoint, key: engine.endpoint.apiKey)
                check.expect(response.status == 200, "a chat request with the enhancer's body answered \(response.status)")

                var content = ""
                for frame in Self.frames(of: response.text) where frame != "[DONE]" {
                    if case .delta(let text, _) = ChatStreamParser.parse(line: "data: \(frame)"), let text { content += text }
                }
                check.expect(!content.isEmpty, "no content delta arrived")
                for marker in Self.reasoningMarkers where content.contains(marker) {
                    check.expect(false, "the content carries the reasoning marker `\(marker)`: \(content.prefix(160))")
                }
                for field in Self.reasoningFields {
                    check.expect(
                        !Self.hasReasoningField(response.text, field),
                        "a chat frame carried a non-empty `\(field)` field although thinking is off")
                }
            }
        }
    }

    /// `chat.length-truncation`: a small `max_tokens` ends with `length`, which the app maps to `chatOutputTruncated`.
    @Test func aTinyMaxTokensEndsTheStreamAsATruncation() async throws {
        try await ContractEngine.run { engine in
            try await runProbe(ContractProbe.chatLengthTruncation.rawValue, ledger: ContractRun.ledger) { check in
                var request = try await Self.loadEnhancer(on: engine)
                request.maxTokens = 4
                do {
                    for try await text in engine.client.streamChat(request) { _ = text }
                    check.expect(false, "a 4-token chat reply completed instead of being cut off")
                } catch EngineError.chatOutputTruncated {
                    // The documented mapping (`ChatStreamParser`: finish_reason "length" -> chatOutputTruncated).
                } catch {
                    check.expect(false, "a truncated chat reply threw \(error), not chatOutputTruncated")
                }
            }
        }
    }

    /// `chat.unknown-model-behavior`: measured at the pin, an unknown model id is *not* something the app can read from
    /// an error. Three observations, in this order (the first needs a fresh engine with nothing loaded):
    ///
    /// 1. With nothing resident, an unknown id answers 503, whose body maps to the app's no-model error.
    /// 2. A registered but unloaded id (the enhancer) answers 200 with text, without a prior `loadModel`: the engine
    ///    loads it on demand.
    /// 3. Once any model is resident, an unknown id still answers 200, served by the resident model, and the response
    ///    echoes the id that was asked for. A missing enhancement model therefore has to be caught by verifying the
    ///    installation locally; the engine will happily answer from whatever it holds.
    @Test func anUnknownModelIDIsOnlyAFailureWhileNothingIsLoaded() async throws {
        try await ContractEngine.run { engine in
            try await runProbe(ContractProbe.chatUnknownModelBehavior.rawValue, ledger: ContractRun.ledger) { check in
                let enhancer = try ContractModels.enhancerID()
                // Never installed by this run: the enhancer's own id with a suffix.
                let absent = enhancer + "-contract-absent"
                let loaded = try await engine.client.models().filter(\.loaded).map(\.id)
                check.expect(loaded.isEmpty, "the fresh engine already holds \(loaded), so the first observation is void")
                let absentRequest = try Self.enhancementRequest(model: absent)
                let absentBody = try JSONSerialization.jsonObject(with: try absentRequest.body())

                // (1) Nothing loaded: the unknown id is a 503 that the app maps to its no-model error.
                let nothingLoaded = try await RawHTTP.send(
                    "POST", "v1/chat/completions", to: engine.endpoint, key: engine.endpoint.apiKey, json: absentBody)
                check.expect(nothingLoaded.status == 503, "an unknown id with nothing loaded answered \(nothingLoaded.status)")
                let mapped = EngineError.fromChatResponse(status: nothingLoaded.status, body: nothingLoaded.body)
                if case .noModel(let message) = mapped {
                    check.expect(message?.isEmpty == false, "the no-model mapping carried no engine text")
                } else {
                    check.expect(false, "an unknown id with nothing loaded mapped to \(mapped), not noModel")
                }

                // (2) Registered but not loaded: a chat answers, and the engine makes the model resident on its own.
                var content = ""
                let registeredRequest = try Self.enhancementRequest(model: enhancer)
                for try await text in engine.client.streamChat(registeredRequest) {
                    content += text
                }
                check.expect(!content.isEmpty, "a chat to the registered but unloaded enhancer returned no text")
                let resident = try await engine.client.models().filter(\.loaded).map(\.id)
                check.expect(resident.contains(enhancer), "the engine never made the enhancer resident: \(resident)")

                // (3) With a model resident, the same unknown id answers 200 from that model.
                let fallenBack = try await RawHTTP.send(
                    "POST", "v1/chat/completions", to: engine.endpoint, key: engine.endpoint.apiKey, json: absentBody)
                check.expect(fallenBack.status == 200, "an unknown id with a resident model answered \(fallenBack.status)")
                check.expect(
                    fallenBack.text.contains(absent),
                    "the fallback response does not echo the requested id \(absent): \(fallenBack.text.prefix(300))")
            }
        }
    }

    /// `chat.keyless-401`: the key rule holds on the chat route too.
    @Test func aChatRequestWithoutTheKeyIs401() async throws {
        try await ContractEngine.run { engine in
            try await runProbe(ContractProbe.chatKeyless401.rawValue, ledger: ContractRun.ledger) { check in
                let request = try await Self.loadEnhancer(on: engine)
                let body = try request.body()
                let json = try JSONSerialization.jsonObject(with: body)
                let response = try await RawHTTP.send(
                    "POST", "v1/chat/completions", to: engine.endpoint, key: nil, json: json)
                check.expect(response.status == 401, "a keyless chat request answered \(response.status)")
                let envelope = ContractErrorEnvelope.decode(response.body)
                check.expect(
                    envelope?.error.message?.isEmpty == false,
                    "the 401 body is not the error envelope the app parses: \(response.text)")
            }
        }
    }

    // MARK: - Requests

    /// Loads the enhancer, then returns the request `PromptEnhancer` builds for the first bundled family that ships a
    /// prompt pack. A memory refusal propagates, so `runProbe` ends the run as inconclusive.
    private static func loadEnhancer(on engine: ContractEngine) async throws -> ChatRequest {
        let enhancer = try ContractModels.enhancerID()
        try await engine.client.load(model: enhancer)
        return try enhancementRequest(model: enhancer)
    }

    /// The request `PromptEnhancer` builds, with `model` named instead of the enhancer's own id, so a probe can ask
    /// for a model the run never installed.
    private static func enhancementRequest(model: String) throws -> ChatRequest {
        for family in try ContractModels.registry().families {
            let build = PromptEnhancer.request(prompt: "a lighthouse at dusk", family: family, enhancerModelID: model)
            if case .ready(let request) = build { return request.chat }
        }
        throw ContractHarnessError.missing("a prompt pack for any family in the bundled registry")
    }

    /// Sends the app's own chat body and returns the whole SSE response. `RawHTTP` re-encodes a JSON object, so the
    /// request carries the same fields and values `ChatRequest.body()` wrote, and the response is buffered whole,
    /// which is what lets a probe decode every frame with the app's parser.
    private static func postEnhancerRequest(
        _ request: ChatRequest, to endpoint: EngineEndpoint, key: String?
    ) async throws -> RawHTTP.Response {
        let json = try JSONSerialization.jsonObject(with: try request.body())
        return try await RawHTTP.send("POST", "v1/chat/completions", to: endpoint, key: key, json: json)
    }

    // MARK: - Frames

    /// The SSE data payloads in order, without the `data:` prefix.
    private static func frames(of body: String) -> [String] {
        body.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            return String(line.dropFirst("data:".count).drop(while: { $0 == " " }))
        }
    }

    /// Every `choices[].finish_reason` the stream reports, in order.
    private static func finishReasons(of body: String) -> [String] {
        var reasons: [String] = []
        for frame in frames(of: body) where frame != "[DONE]" {
            guard let data = frame.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = object["choices"] as? [[String: Any]]
            else { continue }
            for choice in choices {
                if let reason = choice["finish_reason"] as? String { reasons.append(reason) }
            }
        }
        return reasons
    }

    /// Markers a thinking model leaves in its text (deliberation channels and tag pairs).
    private static let reasoningMarkers = ["\u{3C}think>", "\u{3C}/think>", "\u{3C}|channel>", "\u{3C}/thinking>", "\u{3C}|think"]

    /// Wire fields a reasoning stream would fill instead of `content`.
    private static let reasoningFields = ["reasoning_content", "reasoning", "thinking"]

    /// True when any `choices[].delta` carries a non-empty string under `field`.
    private static func hasReasoningField(_ body: String, _ field: String) -> Bool {
        for frame in frames(of: body) where frame != "[DONE]" {
            guard let data = frame.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = object["choices"] as? [[String: Any]]
            else { continue }
            for choice in choices {
                guard let delta = choice["delta"] as? [String: Any],
                    let value = delta[field] as? String, !value.isEmpty
                else { continue }
                return true
            }
        }
        return false
    }
}
