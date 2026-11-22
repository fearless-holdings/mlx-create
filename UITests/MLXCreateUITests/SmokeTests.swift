import XCTest

/// The GUI smoke run (HLD D50): generate one image, then work with it in the gallery. One launch, one generation.
@MainActor
final class SmokeTests: XCTestCase {
    func testGenerateThenRestore() throws {
        continueAfterFailure = false
        let session = try SmokeSession(testCase: self)
        let image = session.runGenerateFlow()
        session.runRestoreFlow(image)
    }

    /// The Chat-mode flow. The runner runs it only with `--agent-model-id`; without it the session skips.
    func testChatConversation() throws {
        continueAfterFailure = false
        let session = try SmokeSession(testCase: self, mode: .chat)
        session.runChatFlow()
    }
}
