import Foundation
import Testing

@testable import MCAgent

@Suite("AgentPlanParser")
struct AgentPlanParserTests {
    @Test func plainGenerateObject() {
        let reply =
            #"{"intent":"make a fox","text":"Making a fox.","action":"generate","model":"m1","prompt":"a fox","size":"wide","seed":"keep","loras":[{"key":"l1","scale":1.5}],"count":3}"#
        #expect(
            AgentPlanParser.parse(reply)
                == .generate(
                    GeneratePlan(
                        text: "Making a fox.", model: "m1", prompt: "a fox", size: "wide",
                        seed: .keep, loras: [PlanLoRA(key: "l1", scale: 1.5)], count: 3)))
    }

    @Test func fencedReplyParses() {
        let reply = "```json\n{\"intent\":\"x\",\"text\":\"Here.\",\"action\":\"say\"}\n```"
        #expect(AgentPlanParser.parse(reply) == .say(text: "Here."))
    }

    @Test func textAroundObjectParses() {
        let reply = "Sure, one moment:\n{\"intent\":\"x\",\"text\":\"Done.\",\"action\":\"say\"}\nThere you go."
        #expect(AgentPlanParser.parse(reply) == .say(text: "Done."))
    }

    @Test func truncatedObjectReturnsNil() {
        #expect(AgentPlanParser.parse(#"{"intent":"x","text":"Making"#) == nil)
        #expect(AgentPlanParser.parse(#"{"intent":"x"#) == nil)
    }

    @Test func unknownActionReturnsNil() {
        #expect(AgentPlanParser.parse(#"{"intent":"x","text":"Hi","action":"download"}"#) == nil)
        #expect(AgentPlanParser.parse("no json at all") == nil)
    }

    @Test func generateWithoutModelOrPromptReturnsNil() {
        #expect(AgentPlanParser.parse(#"{"intent":"x","text":"Hi","action":"generate","prompt":"a fox"}"#) == nil)
        #expect(AgentPlanParser.parse(#"{"intent":"x","text":"Hi","action":"generate","model":"m1"}"#) == nil)
        #expect(AgentPlanParser.parse(#"{"intent":"x","text":"Hi","action":"generate","model":null,"prompt":"a fox"}"#) == nil)
    }

    @Test func missingOrBlankTextReturnsNil() {
        #expect(AgentPlanParser.parse(#"{"intent":"x","action":"say"}"#) == nil)
        #expect(AgentPlanParser.parse(#"{"intent":"x","text":"   ","action":"say"}"#) == nil)
    }

    @Test func askReadsSuggestions() {
        let reply =
            #"{"intent":"x","text":"Which one?","action":"ask","suggestions":["fox","owl",42]}"#
        #expect(AgentPlanParser.parse(reply) == .ask(text: "Which one?", suggestions: ["fox", "owl"]))
    }

    @Test func defaults() {
        let reply = #"{"intent":"x","text":"Making.","action":"generate","model":"m1","prompt":"a fox"}"#
        #expect(
            AgentPlanParser.parse(reply)
                == .generate(
                    GeneratePlan(
                        text: "Making.", model: "m1", prompt: "a fox", size: nil,
                        seed: .new, loras: [], count: 1)))
        // Bad count values fall back to 1; lora entries missing key or scale are dropped.
        let odd =
            #"{"intent":"x","text":"Making.","action":"generate","model":"m1","prompt":"p","count":0,"loras":[{"key":"l1"},{"scale":2},{"key":"l2","scale":0.5}],"seed":"bogus"}"#
        #expect(
            AgentPlanParser.parse(odd)
                == .generate(
                    GeneratePlan(
                        text: "Making.", model: "m1", prompt: "p", size: nil,
                        seed: .new, loras: [PlanLoRA(key: "l2", scale: 0.5)], count: 1)))
    }
}
