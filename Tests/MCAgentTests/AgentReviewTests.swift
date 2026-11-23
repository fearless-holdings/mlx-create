import Foundation
import MCEngine
import Testing

@testable import MCAgent

@Suite("AgentReview")
struct AgentReviewTests {
    @Test func requestShape() throws {
        let jpeg = Data([0xFF, 0xD8])
        let request = AgentReview.request(userRequest: "a red fox", jpeg: jpeg, agentModelID: "agent-id")
        #expect(request.messages.count == 2)
        #expect(request.messages[0].role == .system)
        #expect(request.messages[1].role == .user)
        // The user's request and the image ride the user message; the lead-in's wording is not pinned.
        #expect(request.messages[1].content.hasSuffix("a red fox"))
        #expect(request.messages[1].images.count == 1)
        #expect(request.temperature == 0.5)
        #expect(request.topP == 0.9)
        #expect(request.maxTokens == 200)
        let schema = try #require(request.responseSchemaJSON)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
        #expect(object["required"] as? [String] == ["match", "issue"])
    }

    @Test func parseReadsMatchAndIssue() {
        #expect(
            AgentReview.parse(#"{"match":true,"issue":""}"#) == ReviewVerdict(match: true, issue: ""))
        #expect(
            AgentReview.parse(#"{"match":false,"issue":"wrong count"}"#)
                == ReviewVerdict(match: false, issue: "wrong count"))
        #expect(AgentReview.parse(#"{"match":true}"#) == nil)
        #expect(AgentReview.parse("no json") == nil)
    }

    @Test func streamedIssueIsNilUntilMatchFalse() {
        #expect(AgentReview.streamedIssue(in: #"{"ma"#) == nil)
        #expect(AgentReview.streamedIssue(in: #"{"match":fal"#) == nil)
        #expect(AgentReview.streamedIssue(in: #"{"match":true,"issue":"x"}"#) == nil)
        #expect(AgentReview.streamedIssue(in: #"{"match":false,"issue":""#) == "")
        #expect(AgentReview.streamedIssue(in: #"{"match":false,"issue":"wro"#) == "wro")
        #expect(AgentReview.streamedIssue(in: #"{"match": false , "issue": "wrong count"}"#) == "wrong count")
    }
}
