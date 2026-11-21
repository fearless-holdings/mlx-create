import Foundation
import MCLibrary
import Testing

@testable import MCApp

/// Conversations persist per collection (AE6): a relaunch shows the same messages, and switching collections shows
/// each one's own conversation.
private let helloPlan = #"{"intent":"","text":"Hello back.","action":"say"}"#

@MainActor @Suite struct ChatPersistenceTests {
    @Test func messagesSurviveARelaunch() async throws {
        let first = try await chatHarness(chat: { _, _ in planReply(helloPlan) })
        let chat = first.model.chat!
        await chat.send(text: "hello")
        await chat.turnTask?.value
        let before = chat.messages.map(\.id)
        #expect(before.count == 2)

        let second = try await first.relaunch(
            models: [(kreaModel, "krea2_turbo"), (BrowserFixture.agent.repo, "gemma4")],
            catalog: BrowserFixture.catalogWithAgent)
        await second.model.start()
        try await eventually { second.model.chat.messages.map(\.id) == before }
    }

    @Test func switchingCollectionsShowsEachOnesOwnConversation() async throws {
        let harness = try await chatHarness(chat: { _, _ in planReply(helloPlan) })
        let chat = harness.model.chat!
        await chat.send(text: "hello")
        await chat.turnTask?.value
        let before = chat.messages.map(\.id)
        #expect(before.count == 2)

        _ = try await harness.model.createCollection(name: "Other")
        try await eventually { harness.model.chat.messages.isEmpty }

        await harness.model.switchCollection(to: harness.collectionID)
        try await eventually { !harness.model.chat.messages.isEmpty }
        #expect(harness.model.chat.messages.map(\.id) == before)
    }
}
