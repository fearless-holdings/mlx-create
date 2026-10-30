import XCTest

@MainActor
final class LaunchTests: XCTestCase {
    func testLaunchesInThrowawayHomeWithEmptyLibrary() throws {
        let home = ProcessInfo.processInfo.environment["MLXC_SMOKE_HOME"] ?? ""
        try XCTSkipIf(home.isEmpty, "MLXC_SMOKE_HOME not set: the runner creates the throwaway home (the test runner is sandboxed)")

        let app = XCUIApplication()
        app.launchEnvironment["CFFIXED_USER_HOME"] = home
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-MLXCSmokeHome", home]
        app.launch()

        app.activate()
        let appeared = app.windows.firstMatch.waitForExistence(timeout: 30)
        let tree = XCTAttachment(string: "state=\(app.state.rawValue)\n\(app.debugDescription)")
        tree.name = "tree"
        tree.lifetime = .keepAlways
        add(tree)
        XCTAssertTrue(appeared, "main window never appeared")

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "launch"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(app.staticTexts["No image models installed"].waitForExistence(timeout: 30), "empty-state canvas missing")
    }
}
