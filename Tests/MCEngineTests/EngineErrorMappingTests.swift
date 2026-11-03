import Foundation
import Testing

@testable import MCEngine

@Suite("EngineError mapping (KTD6)")
struct EngineErrorMappingTests {
    @Test("captured 401 body maps to unauthorized with the engine message")
    func unauthorized() throws {
        let body = httpBody(try fixtureData("gen-401-no-key", "http"))
        let error = EngineError.fromResponse(status: 401, body: body)
        #expect(error == .unauthorized(engineMessage: "missing or invalid API key"))
    }

    @Test("captured 400 body maps to badRequest carrying the engine's message")
    func badRequest() throws {
        let body = httpBody(try fixtureData("gen-400-missing-prompt", "http"))
        let error = EngineError.fromResponse(status: 400, body: body)
        #expect(error == .badRequest(engineMessage: "missing 'prompt'"))
    }

    @Test("503 out_of_memory maps to outOfMemory")
    func outOfMemory() throws {
        let body = httpBody(try fixtureData("gen-503-out-of-memory.SYNTHETIC", "http"))
        let error = EngineError.fromResponse(status: 503, body: body)
        guard case .outOfMemory(let message) = error else {
            Issue.record("expected outOfMemory, got \(error)")
            return
        }
        #expect(message?.contains("Not enough free memory") == true)
    }

    @Test("503 no_model maps to noModel")
    func noModel() throws {
        let body = httpBody(try fixtureData("gen-503-no-model.SYNTHETIC", "http"))
        let error = EngineError.fromResponse(status: 503, body: body)
        #expect(error == .noModel(engineMessage: "No default model configured"))
    }

    @Test("503 model_not_loaded maps to modelNotLoaded")
    func modelNotLoaded() {
        let body = Data(#"{"error":{"message":"model is not loaded","type":"model_not_loaded"}}"#.utf8)
        #expect(EngineError.fromResponse(status: 503, body: body) == .modelNotLoaded(engineMessage: "model is not loaded"))
    }

    @Test("an unknown error type keeps its type and message as engineFailure")
    func unknownType() {
        let body = Data(#"{"error":{"message":"kaput","type":"server_error"}}"#.utf8)
        #expect(EngineError.fromResponse(status: 500, body: body) == .engineFailure(type: "server_error", engineMessage: "kaput"))
    }

    @Test("a non-JSON error body keeps its raw text as the engine message")
    func rawTextBody() {
        let body = Data("upstream gateway exploded\n".utf8)
        #expect(EngineError.fromResponse(status: 502, body: body) == .engineFailure(type: nil, engineMessage: "upstream gateway exploded"))
    }

    @Test("every case has a non-empty user-facing message")
    func userMessages() {
        let all: [EngineError] = [
            .unauthorized(engineMessage: nil),
            .outOfMemory(engineMessage: nil),
            .modelNotLoaded(engineMessage: nil),
            .noModel(engineMessage: nil),
            .badRequest(engineMessage: nil),
            .enhancerOutOfMemory(engineMessage: nil),
            .enhancerModelNotLoaded(engineMessage: nil),
            .enhancerBadRequest(engineMessage: nil),
            .engineFailure(type: nil, engineMessage: nil),
            .connectionLost,
            .streamEndedWithoutComplete,
            .timedOut,
            .malformedResponse(detail: "x"),
        ]
        for error in all {
            #expect(!error.userMessage.isEmpty)
        }
    }

    /// The engine's 400 admission refusal body, as upstream `src/server.zig` writes it (I03).
    private static let admissionRefusalJSON =
        #"{"error":{"message":"Prompt (596 tokens) requires ~1001MB GPU memory but only ~510MB is available and the hot "#
        + #"prefix cache holds ~0MB more, all of which can be reclaimed (~0MB — the shortfall is elsewhere), which is not "#
        + #"enough. Reduce prompt size, lower --ctx-size, or use a smaller model.","type":"invalid_request_error"}}"#

    @Test("a 400 admission refusal on a chat route maps to enhancerOutOfMemory")
    func chatAdmissionRefusal() {
        let body = Data(Self.admissionRefusalJSON.utf8)
        guard case .enhancerOutOfMemory = EngineError.fromChatResponse(status: 400, body: body) else {
            Issue.record("expected enhancerOutOfMemory")
            return
        }
    }

    @Test("a plain 400 on a chat route is the enhancer's rejection, not the image engine's")
    func chatBadRequest() throws {
        let body = httpBody(try fixtureData("gen-400-missing-prompt", "http"))
        #expect(EngineError.fromChatResponse(status: 400, body: body) == .enhancerBadRequest(engineMessage: "missing 'prompt'"))
    }

    @Test("the same 400 on an image route is still badRequest")
    func imageRouteAdmissionRefusalStaysBadRequest() {
        let body = Data(Self.admissionRefusalJSON.utf8)
        guard case .badRequest(let message) = EngineError.fromResponse(status: 400, body: body) else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message?.contains("GPU memory") == true)
    }

    @Test("the engine message is kept separate from the user message")
    func engineMessageKept() {
        let error = EngineError.outOfMemory(engineMessage: "needs 17.6 GB")
        #expect(error.engineMessage == "needs 17.6 GB")
        #expect(!error.userMessage.contains("17.6"))
    }
}
