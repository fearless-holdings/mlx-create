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
}
