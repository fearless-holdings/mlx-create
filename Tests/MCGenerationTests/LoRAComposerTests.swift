import Foundation
import MCCatalog
import MCLibrary
import Testing
@testable import MCGeneration

private func stackEntry(_ name: String, weight: Double = 0.8) -> LoRAStackEntry {
    LoRAStackEntry(
        id: name, name: name, sha256: String(repeating: "cd", count: 32), weight: weight,
        relativePath: "LoRAs/krea-2/\(name).safetensors")
}

private func stackRow(_ name: String, enabled: Bool = true, fits: Bool = true, weight: Double = 0.8) -> LoRADraftRow {
    LoRADraftRow(entry: stackEntry(name, weight: weight), isEnabled: enabled, fits: fits)
}

@Suite("GenerationComposer LoRA freeze")
struct LoRAStackFreezeTests {
    @Test func dropsDisabledNonFittingAndZeroWeightRowsAndKeepsOrder() throws {
        let frozen = try GenerationComposer.freezeLoRAs([
            stackRow("a"),
            stackRow("b", enabled: false),
            stackRow("c", fits: false),
            stackRow("d", weight: 0),
            stackRow("e"),
            stackRow("f"),
        ])

        #expect(frozen.map(\.name) == ["a", "e", "f"])
    }

    @Test func eightRemainingRowsFreezeAndNineAreRejected() throws {
        let eight = (1...8).map { stackRow("l\($0)") }
        #expect(try GenerationComposer.freezeLoRAs(eight).count == 8)

        #expect(throws: LoRAStackError.tooMany(count: 9)) {
            try GenerationComposer.freezeLoRAs(eight + [stackRow("l9")])
        }
    }

    @Test func rowsDroppedByTheFilterDoNotCountTowardTheLimit() throws {
        let rows = (1...9).map { stackRow("l\($0)", enabled: $0 != 9) }

        #expect(try GenerationComposer.freezeLoRAs(rows).count == 8)
    }
}

@Suite("GenerationComposer carries the frozen stack onto the job")
struct LoRAComposerEnqueueTests {
    @Test func enqueuedJobCarriesTheStackAndNoneWhenEmpty() async throws {
        let registry = try FamilyRegistry.bundled()
        let harness = try await Harness.make { _, _ in .init(status: 200, body: Data(), tail: nil) }
        let lora = try await harness.installLoRA(name: "Pixel art")
        let family = try #require(registry.family(forArchitecture: "krea2_turbo"))
        let model = InstalledModel(id: kreaModel, architecture: "krea2_turbo", family: family, availability: .available)
        let composer = GenerationComposer(registry: registry, store: harness.store)
        let size = ImageSize(width: 512, height: 512)

        let withLoRA = try await composer.enqueue(
            GenerationDraft(model: model, prompt: "a fox", size: size, loras: [lora]), collectionID: harness.collectionID)
        #expect(withLoRA.request.loras == [lora])

        let without = try await composer.enqueue(
            GenerationDraft(model: model, prompt: "a fox", size: size, loras: []), collectionID: harness.collectionID)
        #expect(without.request.loras == nil)
    }
}
