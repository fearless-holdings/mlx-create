import Foundation
import MCGeneration
import MCLibrary
import Testing

@testable import MCApp

/// The referent image the agent is told about, in D57 order (AE3): the image shown large, then a single gallery
/// selection, then the newest saved image of the conversation's newest result.
private let keepPlan =
    #"{"intent":"","text":"Same again.","action":"generate","model":"m1","prompt":"another stormy lighthouse","size":"square","seed":"keep","loras":[],"count":1}"#
private let firstPlan =
    #"{"intent":"","text":"One lighthouse coming up.","action":"generate","model":"m1","prompt":"a stormy lighthouse","size":"square","seed":"new","loras":[],"count":1}"#

@MainActor @Suite struct ChatReferentTests {
    /// The job the second turn queued, once it is done.
    private func doneJob(_ harness: AppHarness) async throws -> Job {
        try await eventually { try await harness.store.jobs(status: .done).count >= 1 }
        let jobs = try await harness.store.jobs(status: .done)
        return try #require(jobs.last)
    }

    @Test func theImageShownLargeIsTheReferent() async throws {
        let harness = try await chatHarness(
            script: chatImageNow, chat: { _, _ in planReply(keepPlan) })
        let older = try await harness.saveImage(prompt: "an older lighthouse")
        _ = try await harness.saveImage(prompt: "a newer lighthouse")
        let chat = harness.model.chat!
        chat.largeImageID = older.id

        await chat.send(text: "the same again")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        let job = try await doneJob(harness)
        #expect(SeedPolicy(encoded: job.seedPolicy) == .fixed(12345))
        let text = try #require(lastUserText(agentChatRequests(harness)[0].body))
        #expect(text.contains("an older lighthouse"))
        #expect(!text.contains("a newer lighthouse"))
        // A referent the user chose is the picture they have open, not a fallback.
        #expect(text.hasPrefix("[The user has this picture open."))
    }

    @Test func aSingleGallerySelectionIsTheReferent() async throws {
        let harness = try await chatHarness(
            script: chatImageNow, chat: { _, _ in planReply(keepPlan) })
        let picked = try await harness.saveImage(prompt: "the picked lighthouse")
        _ = try await harness.saveImage(prompt: "the other lighthouse")
        let chat = harness.model.chat!
        harness.model.gallerySelection = [picked.id]

        await chat.send(text: "the same again")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        let job = try await doneJob(harness)
        #expect(SeedPolicy(encoded: job.seedPolicy) == .fixed(12345))
        let text = try #require(lastUserText(agentChatRequests(harness)[0].body))
        #expect(text.contains("the picked lighthouse"))
    }

    @Test func theNewestConversationImageIsTheReferent() async throws {
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { number, _ in number == 1 ? planReply(firstPlan) : planReply(keepPlan) })
        let chat = harness.model.chat!

        // Turn one makes the conversation's first image; turn two must point at it.
        await chat.send(text: "a stormy lighthouse")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        guard case .result(let first) = chat.messages[1].body else {
            Issue.record("the first turn did not record a result")
            return
        }
        let firstImage = try #require(try await harness.store.images(jobID: first.jobID).first)

        await chat.send(text: "the same again")
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }

        let jobs = try await harness.store.jobs(status: .done)
        let second = try #require(jobs.last)
        #expect(
            SeedPolicy(encoded: second.seedPolicy)
                == .fixed(try #require(UInt32(exactly: firstImage.settings.seed))))
        // Requests are numbered over every chat call: turn 1's plan, its check, then turn 2's plan.
        let text = try #require(lastUserText(agentChatRequests(harness)[2].body))
        #expect(text.contains("a stormy lighthouse"))
        // The newest-conversation-image fallback is offered "in case", not as the picture being changed.
        #expect(text.hasPrefix("[The last picture you made,"))
    }
}
