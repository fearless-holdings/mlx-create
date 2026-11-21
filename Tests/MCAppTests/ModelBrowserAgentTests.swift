import Foundation
import MCCatalog
import Testing

@testable import MCApp

/// The chat agent's catalog rows and install status in the model browser (D58).
@MainActor
@Suite struct ModelBrowserAgentTests {
    /// The agent is its own group after the enhancers (D58), and it still offers Install like any row.
    @Test func agentRowsSitInTheirOwnGroupAfterTheEnhancers() async throws {
        let rig = try await BrowserRig.make(catalog: BrowserFixture.catalogWithAgent)

        await rig.browser.refresh()

        #expect(
            rig.browser.rows.map(\.id)
                == [BrowserFixture.alpha.id, BrowserFixture.beta.id, BrowserFixture.enhancer.id, BrowserFixture.agent.id])
        #expect(rig.browser.rows(of: .agent).map(\.id) == [BrowserFixture.agent.id])
        let agent = try #require(browserRow(rig.browser.rows, BrowserFixture.agent.id))
        #expect(agent.state == .available)
        #expect(agent.action == .install)
        #expect(agent.canAct)
    }

    /// The agent reports installed the enhancer's way: record and folder, and the engine id only while the engine lists
    /// it (D58).
    @Test func installingTheAgentReportsItsStatusLikeTheEnhancer() async throws {
        let rig = try await BrowserRig.make(catalog: BrowserFixture.catalogWithAgent)
        #expect(rig.browser.agentStatus == LLMStatus(isInstalled: false, engineModelID: nil))

        rig.browser.beginInstall(BrowserFixture.agent.id)
        rig.browser.license.accepted = true
        rig.browser.confirmLicense()
        await rig.browser.installTask?.value

        #expect(rig.transport.requests.map(\.modelID) == [BrowserFixture.agent.id])
        #expect(rig.browser.statuses[BrowserFixture.agent.id] == .installed)
        #expect(rig.browser.agentStatus == LLMStatus(isInstalled: true, engineModelID: nil))

        rig.browser.setEngineModelIDs([BrowserFixture.agent.repo])
        #expect(
            rig.browser.agentStatus
                == LLMStatus(
                    isInstalled: true, engineModelID: BrowserFixture.agent.repo))
    }

    /// The engine lists the agent but no install record exists: the app does not report it installed.
    @Test func engineListingTheAgentWithoutAnInstallRecordIsNotInstalled() async throws {
        let rig = try await BrowserRig.make(
            engineIDs: [BrowserFixture.agent.repo], catalog: BrowserFixture.catalogWithAgent)

        await rig.browser.refresh()

        #expect(rig.browser.agentStatus == LLMStatus(isInstalled: false, engineModelID: nil))
    }
}
