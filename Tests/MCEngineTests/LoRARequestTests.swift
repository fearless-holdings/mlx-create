import Foundation
import Testing
@testable import MCEngine

@Suite("LoRA request fields and 400 mapping")
struct LoRARequestTests {
    private func json(_ request: ImageRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: request.body())
        return try #require(object as? [String: Any])
    }

    @Test func emptyStackOmitsBothLoRAKeys() throws {
        let request = ImageRequest(
            model: "ddalcu/Krea-2-Turbo", prompt: "a fox", width: 512, height: 512, seed: 1,
            loraPaths: [], loraScales: [])
        let body = try json(request)

        #expect(!body.keys.contains("lora_paths"))
        #expect(!body.keys.contains("lora_scales"))
    }

    @Test func unsetStackOmitsBothLoRAKeys() throws {
        let request = ImageRequest(model: "ddalcu/Krea-2-Turbo", prompt: "a fox", width: 512, height: 512, seed: 1)
        let body = try json(request)

        #expect(!body.keys.contains("lora_paths"))
        #expect(!body.keys.contains("lora_scales"))
    }

    @Test func setStackCarriesEqualLengthPathsAndScales() throws {
        let request = ImageRequest(
            model: "ddalcu/Krea-2-Turbo", prompt: "a fox", width: 512, height: 512, seed: 1,
            loraPaths: ["/models/LoRAs/a.safetensors", "/models/LoRAs/b.safetensors"], loraScales: [0.8, -1.5])
        let body = try json(request)

        #expect(body["lora_paths"] as? [String] == ["/models/LoRAs/a.safetensors", "/models/LoRAs/b.safetensors"])
        #expect(body["lora_scales"] as? [Double] == [0.8, -1.5])
    }

    @Test func badRequestNamingNoModulesMatchingIsALoRARejection() {
        let body = Data(#"{"error":{"message":"LoRA rejected: no modules matching the model","type":"invalid_request_error"}}"#.utf8)

        #expect(EngineError.fromResponse(status: 400, body: body)
            == .loraRejected(engineMessage: "LoRA rejected: no modules matching the model"))
    }

    @Test func otherBadRequestsStayBadRequests() {
        let body = Data(#"{"error":{"message":"prompt is empty","type":"invalid_request_error"}}"#.utf8)

        #expect(EngineError.fromResponse(status: 400, body: body) == .badRequest(engineMessage: "prompt is empty"))
    }
}
