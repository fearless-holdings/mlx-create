import Foundation
import MCCatalog
import Testing

@testable import MCApp

/// The license screen discloses the always-on LoRAs of a model's family (D45) and nothing else about them.
@MainActor
@Suite struct ModelBrowserNoticesTests {
    private static func shelfEntry(family: String, alwaysOn: Bool, filename: String) -> LoRAShelfEntry {
        LoRAShelfEntry(
            family: family, role: alwaysOn ? "hidden" : "realism", nsfw: false,
            source: LoRAShelfSource(kind: .civitai, modelID: 1, versionID: 2), filename: filename,
            sha256: String(repeating: alwaysOn ? "1" : "2", count: 64), sizeBytes: 10,
            license: "Published terms for \(filename).", triggerWords: [], testedScale: 1, testedEngine: "v26", alwaysOn: alwaysOn)
    }

    private func rig(shelf: [LoRAShelfEntry]) async throws -> BrowserRig {
        let catalog = Catalog(
            schemaVersion: 1, sequence: 9, issuedAt: BrowserFixture.acceptedAt, models: [BrowserFixture.alpha],
            loraShelf: shelf)
        return try await BrowserRig.make(catalog: catalog)
    }

    @Test func theLicenseScreenListsTheFamilysAlwaysOnLoRAsWithTheirLicenses() async throws {
        let rig = try await rig(shelf: [
            Self.shelfEntry(family: "krea-2-turbo", alwaysOn: true, filename: "measure.safetensors"),
            Self.shelfEntry(family: "krea-2-turbo", alwaysOn: false, filename: "shelf-item.safetensors"),
            Self.shelfEntry(family: "flux2-klein", alwaysOn: true, filename: "other-family.safetensors"),
        ])

        rig.browser.beginInstall(BrowserFixture.alpha.id)

        let notices = try #require(rig.browser.license.pending?.notices)
        #expect(notices == [.init(name: "measure", license: "Published terms for measure.safetensors.")])
    }

    @Test func aFamilyWithoutAnAlwaysOnLoRAShowsNoNotices() async throws {
        let rig = try await rig(shelf: [Self.shelfEntry(family: "krea-2-turbo", alwaysOn: false, filename: "x.safetensors")])

        rig.browser.beginInstall(BrowserFixture.alpha.id)

        #expect(rig.browser.license.pending?.notices.isEmpty == true)
    }
}
