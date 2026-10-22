import Foundation
import Testing

@testable import MCLibrary

/// D44: an always-on row is a real `lora` row that every user-facing query skips.
@Suite struct LoRAAlwaysOnTests {
    /// Never listed, never counted in the library's size, never deletable, and its file survives the open-time sweep, while
    /// the per-family count and rows still reach the executor.
    @Test func anAlwaysOnRowIsHiddenFromTheLibraryButStillReachableAndKept() async throws {
        let fixture = try LoRALibraryTests.makeFixture()
        let visible = try await LoRALibraryTests.importedAlpha(fixture, fill: 16)
        let hidden = try await LoRALibraryTests.importedAlpha(fixture, fill: 17)
        try await fixture.store.setAlwaysOn(id: hidden.id, scale: 0.6)

        #expect(try await fixture.store.loras().map(\.id) == [visible.id])
        #expect(try await fixture.store.loraTotalBytes() == visible.sizeBytes)
        #expect(try await fixture.store.alwaysOnLoRACounts() == [hidden.family: 1])
        #expect(try await fixture.store.alwaysOnLoRAs(family: hidden.family).map(\.alwaysOnScale) == [0.6])
        await #expect(throws: LibraryError.notFound) { _ = try await fixture.store.deleteLoRA(id: hidden.id) }
        #expect(try await fixture.store.loraRecord(id: hidden.id) != nil)

        let libraryRoot = fixture.models.deletingLastPathComponent().appending(path: "Library", directoryHint: .isDirectory)
        let reopened = try LibraryStore(libraryRoot: libraryRoot, modelsRoot: fixture.models)
        #expect(reopened.loraFileExists(hidden))
    }
}
