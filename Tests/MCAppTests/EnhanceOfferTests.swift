import Foundation
import MCCatalog
import MCModels
import Testing

@testable import MCApp

/// An app with the enhancer in the catalog. `installed` runs the browser's real license-then-install flow for it.
/// The app is started before any install, so the install's rescan can run.
@MainActor
private func offerHarness(installed: Bool) async throws -> (harness: AppHarness, transport: ScriptedTransport) {
    let root = FileManager.default.temporaryDirectory.appending(path: "enhance-offer-\(UUID().uuidString)")
    let transport = ScriptedTransport(
        modelsRoot: root.appending(path: "Models", directoryHint: .isDirectory), outcomes: [.completes])
    let harness = try await AppHarness.make(
        models: [(id: kreaModel, architecture: "krea2_turbo"), (id: BrowserFixture.enhancer.repo, architecture: "gemma4")],
        catalog: BrowserFixture.catalogWithEnhancer, transport: transport, root: root)
    await harness.model.start()
    if installed {
        harness.model.browser.beginInstall(BrowserFixture.enhancer.id)
        harness.model.license.accepted = true
        harness.model.browser.confirmLicense()
        await harness.model.browser.installTask?.value
        await harness.model.refreshModels()
    }
    return (harness, transport)
}

/// A copy of a family with a different id, which the prompt packs do not cover, so the enhancer refuses it.
private func familyWithoutPack(_ family: ModelFamily) throws -> ModelFamily {
    let data = try JSONEncoder().encode(family)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["id"] = "no-pack-family"
    return try JSONDecoder().decode(ModelFamily.self, from: JSONSerialization.data(withJSONObject: object))
}

@MainActor
@Suite struct EnhanceOfferTests {
    // MARK: Offer

    @Test func anEnhancerNotInTheCatalogOrAlreadyInstalledIsNotOffered() {
        #expect(!EnhancerOffer.isOffered(nil))
        #expect(!EnhancerOffer.isOffered(LLMStatus(isInstalled: true, engineModelID: nil)))
        #expect(EnhancerOffer.isOffered(LLMStatus(isInstalled: false, engineModelID: nil)))
    }

    @Test func theEnhancerIsOfferedWhileNotInstalledAndNotOnceInstalled() async throws {
        let (notInstalled, _) = try await offerHarness(installed: false)
        #expect(EnhancerOffer.isOffered(notInstalled.model.enhancer))

        let (installed, _) = try await offerHarness(installed: true)
        #expect(!EnhancerOffer.isOffered(installed.model.enhancer))
    }

    @Test func aCatalogWithoutAnEnhancerOffersNothing() async throws {
        let harness = try await AppHarness.make()
        #expect(!EnhancerOffer.isOffered(harness.model.enhancer))
    }

    // MARK: Enhance with no enhancer installed (F2)

    @Test func enhanceWithoutAnEnhancerOpensTheInstallSheetAndAcceptingStartsTheInstallAndLeavesThePrompt() async throws {
        let (harness, transport) = try await offerHarness(installed: false)
        let model = harness.model
        model.selectedModelID = kreaModel
        await model.refreshModels()
        model.prompt = "a lighthouse"

        await model.pressEnhance()

        #expect(model.isEnhancerInstallPresented)
        #expect(model.enhanceState == .idle)
        #expect(model.prompt == "a lighthouse")
        let row = try #require(model.browser.rows(of: .enhancer).first)
        #expect(EnhancerInstallPhase.phase(for: row) == .ready)
        let catalogModel = try #require(row.model)
        #expect(catalogModel.downloadBytes == BrowserFixture.enhancer.downloadBytes)
        #expect(catalogModel.license.name == BrowserFixture.enhancer.license.name)

        // Install goes through the same license-then-install flow the browser uses.
        model.browser.beginInstall(BrowserFixture.enhancer.id)
        #expect(model.license.pending?.model.id == BrowserFixture.enhancer.id)
        model.license.accepted = true
        model.browser.confirmLicense()
        await model.browser.installTask?.value

        #expect(transport.requests.map(\.modelID) == [BrowserFixture.enhancer.id])
        #expect(model.license.pending == nil)
        #expect(model.prompt == "a lighthouse")
        #expect(EnhancerInstallPhase.phase(for: model.browser.rows(of: .enhancer).first) == .installed)
    }

    @Test func aFailedEnhancerDownloadReadsFailedWithRetry() async throws {
        let failure = InstallError.network(path: "model.safetensors", reason: "the connection was lost")
        let rig = try await BrowserRig.make(outcomes: [.fails(failure)], catalog: BrowserFixture.catalogWithEnhancer)

        rig.browser.beginInstall(BrowserFixture.enhancer.id)
        rig.browser.license.accepted = true
        rig.browser.confirmLicense()
        await rig.browser.installTask?.value

        let phase = EnhancerInstallPhase.phase(for: rig.browser.rows(of: .enhancer).first)
        #expect(phase == .failed(message: ModelBrowserModel.failureMessage(for: failure), retryable: true))
    }

    @Test func aCatalogWithoutAnEnhancerReadsUnavailable() async throws {
        let rig = try await BrowserRig.make()

        #expect(EnhancerInstallPhase.phase(for: rig.browser.rows(of: .enhancer).first) == .unavailable)
    }

    // MARK: Caption and availability

    @Test func anEmptyPromptDisablesEnhanceWithoutACaption() async throws {
        let harness = try await AppHarness.make()
        // refreshModels waits on the engine gate, which only opens once the app has started.
        await harness.model.start()
        harness.model.selectedModelID = kreaModel
        await harness.model.refreshModels()

        harness.model.prompt = "   "
        #expect(!harness.model.canEnhance)
        #expect(harness.model.enhanceBlockReason == nil)

        harness.model.prompt = "a lighthouse"
        #expect(harness.model.canEnhance)
    }

    @Test func aSelectionWithNoModelGivesTheNoModelReason() async throws {
        let harness = try await AppHarness.make()
        harness.model.selectedModelID = nil
        harness.model.prompt = "a lighthouse"

        #expect(harness.model.enhanceBlockReason == AppModel.noModelReason)
        #expect(!harness.model.canEnhance)
    }

    @Test func aFamilyWithoutAPromptPackExposesItsReasonAndAPackedFamilyDoesNot() async throws {
        let harness = try await AppHarness.make()
        await harness.model.start()
        harness.model.selectedModelID = kreaModel
        await harness.model.refreshModels()
        let krea = try #require(harness.model.enhanceFamily)

        #expect(EnhanceAvailability.blockReason(family: krea) == nil)
        let unpacked = try familyWithoutPack(krea)
        #expect(EnhanceAvailability.blockReason(family: unpacked) != nil)
        #expect(EnhanceAvailability.blockReason(family: nil) == AppModel.noModelReason)
    }

    // MARK: One-time reload note

    @Test func theReloadNoteIsDueOnlyOnATierThatReloadsAndOnceAfterThat() {
        let defaults = UserDefaults(suiteName: "enhance-note-\(UUID().uuidString)")!

        #expect(!EnhanceReloadNote.isDue(willReloadImageModel: false, defaults: defaults))
        #expect(EnhanceReloadNote.isDue(willReloadImageModel: true, defaults: defaults))

        EnhanceReloadNote.markShown(in: defaults)
        #expect(!EnhanceReloadNote.isDue(willReloadImageModel: true, defaults: defaults))
    }
}
