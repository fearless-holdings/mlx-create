import Foundation
import MCLibrary
import Testing

@testable import MCApp

/// A large view that still shows the image a turn started from follows to each image the turn lands (D54/F2): the
/// newest result stays open and becomes the next turn's explicit referent. Closing the large view or opening another
/// image in the meantime ends the follow.
private let lfFirstPlan =
    #"{"intent":"","text":"One fox coming up.","action":"generate","model":"m1","prompt":"a sitting fox","size":"square","seed":"new","loras":[],"count":1}"#
private let lfNextPlan =
    #"{"intent":"","text":"Same again.","action":"generate","model":"m1","prompt":"a standing fox","size":"square","seed":"new","loras":[],"count":1}"#
private let lfPairPlan =
    #"{"intent":"","text":"Two foxes.","action":"generate","model":"m1","prompt":"a standing fox","size":"square","seed":"new","loras":[],"count":2}"#

@MainActor @Suite struct ChatLargeFollowTests {
    /// Drives one turn to idle and returns its saved images.
    @discardableResult
    private func turn(_ harness: AppHarness, _ text: String) async throws -> [LibraryImage] {
        let chat = harness.model.chat!
        let before = Set(chat.messages.map(\.id))
        await chat.send(text: text)
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
        let result = chat.messages.last { message in
            if case .result = message.body, !before.contains(message.id) { return true }
            return false
        }
        guard let jobID = result?.jobID else { return [] }
        return try await harness.store.images(jobID: jobID)
    }

    /// Sends while the image render is held, changes `largeImageID` mid-render, releases and waits for idle.
    private func sendHeldThenRelease(
        _ harness: AppHarness, _ text: String, changeLargeImageTo imageID: UUID?
    ) async throws {
        let chat = harness.model.chat!
        await chat.send(text: text)
        try await harness.engineHasReceived("v1/images/generations")
        chat.largeImageID = imageID
        EngineStubProtocol.finishHeld(harness.endpoint)
        await chat.turnTask?.value
        try await eventually { chat.phase == .idle }
    }

    @Test func aLandedImageTakesTheLargeViewAndBecomesTheNextReferent() async throws {
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { number, _ in number == 1 ? planReply(lfFirstPlan) : planReply(lfNextPlan) })
        let chat = harness.model.chat!

        // Turn 1 lands A; the user has it large when turn 2's job is queued.
        let imageA = try #require(try await turn(harness, "a sitting fox").first)
        chat.largeImageID = imageA.id

        // Turn 2's image lands: the large view switches to it.
        let imageB = try #require(try await turn(harness, "make it stand").first)
        #expect(chat.largeImageID == imageB.id)

        // Turn 3's referent is the image now open — B — labelled as the one the user has open.
        _ = try await turn(harness, "make it jump")
        let request = try #require(
            agentChatRequests(harness).last {
                lastUserText($0.body)?.hasPrefix("[The user has this picture open.") == true
            })
        let text = try #require(lastUserText(request.body))
        #expect(text.contains("a standing fox"))
        #expect(!text.contains("a sitting fox"))
    }

    @Test func aClosedLargeViewStaysClosedWhenTheImageLands() async throws {
        let harness = try await chatHarness(
            script: chatImageHeld, chat: { _, _ in planReply(lfFirstPlan) })
        let imageA = try await harness.saveImage(prompt: "a sitting fox")
        harness.model.chat!.largeImageID = imageA.id

        try await sendHeldThenRelease(harness, "make it stand", changeLargeImageTo: nil)
        #expect(harness.model.chat!.largeImageID == nil)
    }

    @Test func anotherImageOpenedLargeEndsTheFollow() async throws {
        let harness = try await chatHarness(
            script: chatImageHeld, chat: { _, _ in planReply(lfFirstPlan) })
        let imageA = try await harness.saveImage(prompt: "a sitting fox")
        let imageC = try await harness.saveImage(prompt: "a running fox")
        harness.model.chat!.largeImageID = imageA.id

        try await sendHeldThenRelease(harness, "make it stand", changeLargeImageTo: imageC.id)
        #expect(harness.model.chat!.largeImageID == imageC.id)
    }

    @Test func aBatchFollowsToTheImageThatLandedLast() async throws {
        let harness = try await chatHarness(
            script: chatImageNow, chat: { _, _ in planReply(lfPairPlan) })
        let imageA = try await harness.saveImage(prompt: "a sitting fox")
        harness.model.chat!.largeImageID = imageA.id

        let images = try await turn(harness, "two foxes")
        #expect(images.count == 2)
        #expect(harness.model.chat!.largeImageID == images.last?.id)
    }

    @Test func nothingOpenLargeStaysNothing() async throws {
        let harness = try await chatHarness(
            script: chatImageNow, chat: { _, _ in planReply(lfFirstPlan) })
        #expect(harness.model.chat!.largeImageID == nil)

        _ = try await turn(harness, "a sitting fox")
        #expect(harness.model.chat!.largeImageID == nil)
    }
}
