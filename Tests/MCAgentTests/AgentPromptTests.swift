import Foundation
import MCCatalog
import MCEngine
import MCEnhancer
import MCLibrary
import Testing

@testable import MCAgent

@Suite("AgentPrompt")
struct AgentPromptTests {
    @Test func schemaParsesAsJSONAndListsModelKeys() throws {
        let context = AgentFixture.twoModelContext()
        let request = AgentPrompt.request(context: context, agentModelID: "agent-id")
        let schema = try #require(request.responseSchemaJSON)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: Any])
        let model = try #require(properties["model"] as? [String: Any])
        #expect(model["enum"] as? [String] == ["m1", "m2"])
        let size = try #require(properties["size"] as? [String: Any])
        #expect(size["enum"] as? [String] == ["square", "landscape", "portrait", "wide", "tall"])
        #expect(properties["loras"] != nil)
        #expect(properties["steps"] == nil)
        #expect(properties["negative_prompt"] == nil)
        // Field order is fixed: intent, then text, then action.
        let intentIndex = try #require(schema.range(of: "\"intent\""))
        let textIndex = try #require(schema.range(of: "\"text\""))
        let actionIndex = try #require(schema.range(of: "\"action\""))
        #expect(intentIndex.lowerBound < textIndex.lowerBound)
        #expect(textIndex.lowerBound < actionIndex.lowerBound)
    }

    @Test func schemaOmitsLorasWhenNoOptions() throws {
        let context = AgentFixture.context(
            turns: [AgentTurn(speaker: .user, text: "hi")],
            models: AgentFixture.twoModelContext().models)
        let schema = try #require(AgentPrompt.request(context: context, agentModelID: "a").responseSchemaJSON)
        #expect(!schema.contains("\"loras\""))
    }

    @Test func systemMessageCarriesFidelityRuleAndModelKeys() {
        let context = AgentFixture.twoModelContext()
        let request = AgentPrompt.request(context: context, agentModelID: "agent-id")
        let system = request.messages[0]
        #expect(system.role == .system)
        #expect(system.content.contains(PromptEnhancer.fidelityRule))
        #expect(system.content.contains("m1"))
        #expect(system.content.contains("m2"))
        #expect(system.content.contains("l1"))
        #expect(system.content.contains("l2"))
        #expect(!system.content.contains("{MODEL_LINES}"))
        #expect(!system.content.contains("{FIDELITY_RULE}"))
    }

    @Test func messagesAlternateAndEndWithUser() {
        let context = AgentFixture.context(
            turns: [
                AgentTurn(speaker: .agent, text: "stray agent open"),
                AgentTurn(speaker: .user, text: "first"),
                AgentTurn(speaker: .user, text: "second"),
                AgentTurn(speaker: .agent, text: "reply"),
                AgentTurn(speaker: .user, text: "last"),
            ],
            models: AgentFixture.twoModelContext().models)
        let request = AgentPrompt.request(context: context, agentModelID: "agent-id")
        let roles = request.messages.map(\.role)
        #expect(roles == [.system, .user, .assistant, .user])
        // Same-speaker turns join with a blank line; the leading agent turn is dropped.
        #expect(request.messages[1].content == "first\n\nsecond")
        #expect(request.messages[2].content == "reply")
        #expect(request.messages[3].content == "last")
    }

    @Test func referentPrefixesLastUserMessageAndAttachesImage() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let lora = AgentFixture.loraOption(key: "l1", triggerWords: ["trig"])
        var settings = AgentFixture.settings(
            modelID: "model-a", width: 1024, height: 768, prompt: "a fox")
        settings.loras = [ImageLoRA(name: "l1", sha256: "sha-l1", weight: 0.8)]
        let context = AgentFixture.context(
            turns: [
                AgentTurn(speaker: .agent, text: "Making a fox."),
                AgentTurn(speaker: .user, text: "make it snow"),
            ],
            referent: AgentReferent(settings: settings, jpeg: jpeg),
            models: [
                AgentFixture.modelOption(
                    key: "m1", model: AgentFixture.model(id: "model-a", family: AgentFixture.kreaLike),
                    family: AgentFixture.kreaLike)
            ],
            loras: [lora])
        let request = AgentPrompt.request(context: context, agentModelID: "agent-id")
        let last = try #require(request.messages.last)
        #expect(last.role == .user)
        #expect(last.images.count == 1)
        #expect(
            last.content.hasPrefix(
                "[The picture the user is talking about was made with: {\"model\":\"m1\",\"size\":\"landscape\",\"prompt\":\"a fox\",\"loras\":[{\"key\":\"l1\",\"scale\":0.8}]}]\n\n"
            ))
        #expect(last.content.hasSuffix("make it snow"))
    }

    @Test func replayedTurnIsTheReplyObject() {
        let context = AgentFixture.twoModelContext()
        #expect(
            AgentPrompt.replayedTurn(text: "Hi.", action: "say", job: nil, context: context)
                == #"{"intent":"","text":"Hi.","action":"say"}"#)
        let job = JobRequest(
            modelID: "model-qwen", family: "fam-qwen", prompt: "a fox",
            width: 1344, height: 768,
            loras: [
                LoRAStackEntry(id: "x", name: "n", sha256: "sha-l1", weight: 0.5, relativePath: "p")
            ])
        #expect(
            AgentPrompt.replayedTurn(text: "Making a fox.", action: "generate", job: job, context: context)
                == #"{"intent":"","text":"Making a fox.","action":"generate","model":"m1","prompt":"a fox","size":"wide","loras":[{"key":"l1","scale":0.5}]}"#
        )
    }
}
