import Foundation
import Testing
@testable import MCEngine

@Suite("ImageRequest body")
struct ImageRequestTests {
    private func json(_ request: ImageRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: request.body())
        return try #require(object as? [String: Any])
    }

    @Test("minimal request carries only the required fields and stream true")
    func minimalBody() throws {
        let request = ImageRequest(model: "ddalcu/Krea-2-Turbo", prompt: "a fox", width: 512, height: 512, seed: 42)
        let body = try json(request)

        #expect(Set(body.keys) == ["model", "prompt", "seed", "size", "stream"])
        #expect(body["model"] as? String == "ddalcu/Krea-2-Turbo")
        #expect(body["prompt"] as? String == "a fox")
        #expect(body["size"] as? String == "512x512")
        #expect(body["seed"] as? Int == 42)
        #expect(body["stream"] as? Bool == true)
    }

    @Test("steps, guidance and negative prompt are included when set")
    func optionalFieldsIncluded() throws {
        let request = ImageRequest(
            model: "ddalcu/Krea-2-Turbo",
            prompt: "a fox",
            negativePrompt: "blurry",
            width: 768,
            height: 512,
            steps: 8,
            guidance: 3.5,
            seed: 7
        )
        let body = try json(request)

        #expect(body["negative_prompt"] as? String == "blurry")
        #expect(body["steps"] as? Int == 8)
        #expect(body["guidance_scale"] as? Double == 3.5)
        #expect(body["size"] as? String == "768x512")
    }
}
