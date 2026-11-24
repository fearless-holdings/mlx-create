import Foundation
import MCLibrary
import Testing

@testable import MCApp

/// A chat job's landed image becomes the highlighted tile and clears a lone gallery selection (R7): the selection is
/// an explicit referent, and a stale one would make the next message about the wrong picture. A multi-selection is
/// left alone, and nothing changes outside Chat mode.
private let selFirstPlan =
    #"{"intent":"","text":"One fox coming up.","action":"generate","model":"m1","prompt":"a sitting fox","size":"square","seed":"new","loras":[],"count":1}"#
private let selNextPlan =
    #"{"intent":"","text":"Same again.","action":"generate","model":"m1","prompt":"a standing fox","size":"square","seed":"new","loras":[],"count":1}"#

@MainActor @Suite struct ChatSelectionTests {
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

    @Test func aLandedImageClearsALoneSelectionSoTheNextReferentIsImplicit() async throws {
        let harness = try await chatHarness(
            script: chatImageNow,
            chat: { number, _ in number == 1 ? planReply(selFirstPlan) : planReply(selNextPlan) })

        // Turn 1 lands image A; the user clicks it, which selects it as the picture they mean.
        let firstImages = try await turn(harness, "a sitting fox")
        let imageA = try #require(firstImages.first)
        harness.model.selectGalleryImage(imageA.id, click: .plain)
        #expect(harness.model.gallerySelection == [imageA.id])

        // Turn 2 lands image B: the new tile is highlighted and the stale selection is cleared.
        let secondImages = try await turn(harness, "make it stand")
        let imageB = try #require(secondImages.first)
        #expect(harness.model.gallerySelection.isEmpty)
        #expect(harness.model.selection == imageB.id)

        // Turn 3's referent is the implicit newest-image fallback — B — not the cleared click.
        let context = await harness.model.chat!.buildContext(history: [], newUserText: "make it jump")
        #expect(context.referent?.isExplicit == false)
        #expect(context.referent?.settings == imageB.settings)
        _ = try await turn(harness, "make it jump")
    }

    @Test func aLandedImageLeavesAMultiSelectionAlone() async throws {
        let harness = try await chatHarness(
            script: chatImageNow, chat: { _, _ in planReply(selFirstPlan) })
        let imageA = try await harness.saveImage(prompt: "a sitting fox")
        let imageB = try await harness.saveImage(prompt: "a running fox")
        harness.model.gallerySelection = [imageA.id, imageB.id]

        let landed = try await turn(harness, "a fox")
        #expect(harness.model.gallerySelection == [imageA.id, imageB.id])
        #expect(harness.model.selection == landed.first?.id)
    }

    @Test func aLandedImageKeepsALoneSelectionOutsideChatMode() async throws {
        let harness = try await chatHarness(
            script: chatImageNow, chat: { _, _ in planReply(selFirstPlan) })
        let imageA = try await harness.saveImage(prompt: "a sitting fox")
        harness.model.selectGalleryImage(imageA.id, click: .plain)
        harness.model.windowMode = .canvas

        let landed = try await turn(harness, "a fox")
        #expect(harness.model.gallerySelection == [imageA.id])
        #expect(harness.model.selection == landed.first?.id)
    }
}
