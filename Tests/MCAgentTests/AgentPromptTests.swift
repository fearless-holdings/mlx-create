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

    @Test func offeredModelIsASchemaKeyMarkedNotInstalled() throws {
        let context = AgentFixture.context(
            turns: [AgentTurn(speaker: .user, text: "hi")],
            models: [
                AgentFixture.modelOption(
                    key: "m1", model: AgentFixture.model(family: AgentFixture.kreaLike),
                    family: AgentFixture.kreaLike),
                AgentFixture.offeredOption(key: "m2", family: AgentFixture.kreaLike),
            ])
        let request = AgentPrompt.request(context: context, agentModelID: "a")
        let schema = try #require(request.responseSchemaJSON)
        #expect(schema.contains("\"m2\""))
        // An offered option is marked on its own model line, not hidden (D60): the installed option's line carries
        // no such note. The check is scoped to each key's line and case-insensitive, so the phrasing can move.
        let lines = request.messages[0].content.split(separator: "\n")
        let offeredLine = try #require(lines.first { $0.hasPrefix("m2:") })
        #expect(offeredLine.localizedCaseInsensitiveContains("not installed"))
        let installedLine = try #require(lines.first { $0.hasPrefix("m1:") })
        #expect(!installedLine.localizedCaseInsensitiveContains("not installed"))
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

    /// A context with one model, one installed LoRA and the referent of `isExplicit`.
    private func referentContext(isExplicit: Bool) -> AgentContext {
        let lora = AgentFixture.loraOption(key: "l1", triggerWords: ["trig"])
        var settings = AgentFixture.settings(
            modelID: "model-a", width: 1024, height: 768, prompt: "a fox")
        settings.loras = [ImageLoRA(name: "l1", sha256: "sha-l1", weight: 0.8)]
        return AgentFixture.context(
            turns: [
                AgentTurn(speaker: .agent, text: "Making a fox."),
                AgentTurn(speaker: .user, text: "make it snow"),
            ],
            referent: AgentReferent(
                settings: settings, jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), isExplicit: isExplicit),
            models: [
                AgentFixture.modelOption(
                    key: "m1", model: AgentFixture.model(id: "model-a", family: AgentFixture.kreaLike),
                    family: AgentFixture.kreaLike)
            ],
            loras: [lora])
    }

    /// The bracketed lead-in before the referent's settings JSON, nil when no such block leads the message.
    private func referentLeadIn(of content: String) -> String? {
        guard let openBrace = content.firstIndex(of: "{") else { return nil }
        return String(content[..<openBrace])
    }

    /// The fixture referent's decoded settings — field checks, never the serialized bytes (no wording pinned).
    private func expectReferentSettings(in content: String) throws {
        let jsonStart = try #require(content.firstIndex(of: "{"))
        let blockEnd = try #require(content.range(of: "]\n\n"))
        let object = try JSONSerialization.jsonObject(
            with: Data(content[jsonStart..<blockEnd.lowerBound].utf8))
        let decoded = try #require(object as? [String: Any])
        #expect(decoded["model"] as? String == "m1")
        #expect(decoded["size"] as? String == "landscape")
        #expect(decoded["prompt"] as? String == "a fox")
        let loras = try #require(decoded["loras"] as? [[String: Any]])
        #expect(loras.count == 1)
        #expect(loras[0]["key"] as? String == "l1")
        #expect(loras[0]["scale"] as? Double == 0.8)
    }

    @Test func anExplicitReferentIsFramedAsTheOpenPicture() throws {
        let request = AgentPrompt.request(
            context: referentContext(isExplicit: true), agentModelID: "agent-id")
        let last = try #require(request.messages.last)
        #expect(last.role == .user)
        #expect(last.images.count == 1)
        // The framing, the placement and the decoded settings, not the lead-in's wording: the explicit referent
        // reads as the picture the user has open, in a bracketed block before the user's text.
        let leadIn = try #require(referentLeadIn(of: last.content))
        #expect(leadIn.localizedCaseInsensitiveContains("open"))
        try expectReferentSettings(in: last.content)
        #expect(last.content.hasSuffix("make it snow"))
    }

    @Test func anImplicitReferentIsFramedAsAFallback() throws {
        let request = AgentPrompt.request(
            context: referentContext(isExplicit: false), agentModelID: "agent-id")
        let last = try #require(request.messages.last)
        // The fallback is introduced as a possibility, never as the picture the user has open.
        let leadIn = try #require(referentLeadIn(of: last.content))
        #expect(leadIn.localizedCaseInsensitiveContains("in case"))
        #expect(!leadIn.localizedCaseInsensitiveContains("open"))
        try expectReferentSettings(in: last.content)
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
