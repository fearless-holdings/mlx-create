import Foundation
import MCCatalog
import MCEngine
import MCLibrary
import Testing

@testable import MCApp

/// The after-image check (D59, KTD11): a single-image result earns one more leased chat call with the made image; a
/// clear miss records a `.miss`, a match, an unreadable reply, an error or a cancel records nothing, and a send
/// during the check cancels it.
private let reviewPlan =
    #"{"intent":"","text":"One fox coming up.","action":"generate","model":"m1","prompt":"a fox in snow","size":"square","seed":"new","loras":[],"count":1}"#
private let reviewPlanThree =
    #"{"intent":"","text":"Three foxes coming up.","action":"generate","model":"m1","prompt":"a fox in snow","size":"square","seed":"new","loras":[],"count":3}"#
private let missVerdict = #"{"match": false, "issue": "There is no fox in the picture."}"#
private let matchVerdict = #"{"match": true, "issue": ""}"#
private let afterSayPlan = #"{"intent":"","text":"Of course.","action":"say"}"#

@MainActor @Suite struct ChatReviewTests {
    /// A turn that made one image and finished: the harness, its chat model and the job, with the check's reply
    /// scripted as `review`.
    private func madeImage(
        review: EngineStubProtocol.Reply
    ) async throws -> (harness: AppHarness, chat: ChatModel) {
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { number, _ in
                switch number {
                case 1: planReply(reviewPlan)
                case 2: review
                default: planReply(afterSayPlan)
                }
            })
        let chat = harness.model.chat!
        await chat.send(text: "a fox in snow")
        await chat.turnTask?.value
        try await eventually {
            if case .checking = chat.phase { return true }
            return chat.phase == .idle
        }
        return (harness, chat)
    }

    private func missBodies(_ chat: ChatModel) -> [ChatMiss] {
        chat.messages.compactMap {
            if case .miss(let miss) = $0.body { return miss }
            return nil
        }
    }

    @Test func aClearMissRecordsOneMiss() async throws {
        let (harness, chat) = try await madeImage(review: planReply(missVerdict))
        try await harness.engineHasReceived(agentChatPath, count: 2)
        try await eventually { chat.phase == .idle }

        let miss = try #require(missBodies(chat).last)
        #expect(miss.text == "There is no fox in the picture.")
        #expect(miss.fixRequest == "Fix this: There is no fox in the picture.")
        #expect(miss.used == false)
    }

    @Test func aMatchRecordsNothing() async throws {
        let (harness, chat) = try await madeImage(review: planReply(matchVerdict))
        try await harness.engineHasReceived(agentChatPath, count: 2)
        try await eventually { chat.phase == .idle }

        #expect(missBodies(chat).isEmpty)
        if chat.messages.count != 2 {
            Issue.record("messages: \(chat.messages.map { "\($0.body)" })")
            return
        }
    }

    @Test func aMultiImageResultIsNotChecked() async throws {
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { _, _ in planReply(reviewPlanThree) })
        let chat = harness.model.chat!

        await chat.send(text: "three foxes in snow")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        try await eventually { try await harness.store.jobs(status: .done).count == 1 }

        // The plan's chat call is the only one: no review call was made.
        #expect(agentChatRequests(harness).count == 1)
        #expect(missBodies(chat).isEmpty)
    }

    @Test func aSendDuringTheCheckCancelsItAndRunsTheTurn() async throws {
        let (harness, chat) = try await madeImage(
            review: heldPlanReply(missVerdict))
        try await harness.engineHasReceived(agentChatPath, count: 2)
        try await eventually { chat.streamingText != nil }
        guard case .checking = chat.phase else {
            Issue.record("the check did not start: \(chat.phase)")
            return
        }
        #expect(chat.streamingText == "There is no fox in the picture.")

        await chat.send(text: "try again, wider")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        // The held check was cancelled — no miss — and the new turn's reply recorded.
        #expect(missBodies(chat).isEmpty)
        guard case .agentText(let reply) = chat.messages.last?.body else {
            Issue.record("the new turn did not record its reply")
            return
        }
        #expect(reply == "Of course.")
        #expect(agentChatRequests(harness).count == 3)
    }

    @Test func fixSendsTheRequestWithTheCheckedImageAsReferent() async throws {
        let (harness, chat) = try await madeImage(review: planReply(missVerdict))
        try await harness.engineHasReceived(agentChatPath, count: 2)
        try await eventually { chat.phase == .idle }
        let missID = try #require(
            chat.messages.last { message in
                if case .miss = message.body { return true }
                return false
            }
        ).id

        // Whatever is shown large, the checked image is the referent (D59).
        let other = try await harness.saveImage(prompt: "an unrelated picture")
        chat.largeImageID = other.id

        await chat.fix(messageID: missID)
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        #expect(missBodies(chat).last?.used == true)
        try await eventually { agentChatRequests(harness).count >= 3 }
        let text = try #require(lastUserText(agentChatRequests(harness)[2].body))
        #expect(text.contains("Fix this: There is no fox in the picture."))
        #expect(text.contains("a fox in snow"))
        #expect(!text.contains("an unrelated picture"))
    }
}
