import XCTest

/// One ordered smoke run (KTD5): a single app launch, named steps, and a `.keepAlways` screenshot after every step (KTD8).
/// The runner (`scripts/gui-smoke/run_smoke.py`) owns the throwaway home: the test runner is sandboxed, so this only reads it.
@MainActor
final class SmokeSession {
    let app = XCUIApplication()
    let modelID: String
    private let testCase: XCTestCase
    private var stepCount = 0

    init(testCase: XCTestCase) throws {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["MLXC_SMOKE_HOME"] ?? ""
        modelID = environment["MLXC_SMOKE_MODEL_ID"] ?? ""
        try XCTSkipIf(
            home.isEmpty || modelID.isEmpty,
            "Run through scripts/gui-smoke/run_smoke.py: it builds the throwaway home and passes the model id")
        self.testCase = testCase
        // CFFIXED_USER_HOME redirects the library, models and engine. The marker pair keeps the home in the app's command
        // line for path-based cleanup; a bare path argument would be opened as a document and suppress the window. The
        // persistence flag stops macOS restoring zero windows from an earlier session (docs/lld/gui-smoke.md section 4).
        app.launchEnvironment["CFFIXED_USER_HOME"] = home
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-MLXCSmokeHome", home]
    }

    /// Runs `body` as a named activity and attaches a screenshot of the window afterwards.
    func step<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        stepCount += 1
        let label = String(format: "%02d %@", stepCount, name)
        return try XCTContext.runActivity(named: label) { _ in
            let result = try body()
            attachScreenshot(named: label)
            return result
        }
    }

    func attachScreenshot(named name: String) {
        let window = app.windows.firstMatch
        let attachment = XCTAttachment(screenshot: window.exists ? window.screenshot() : XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    /// Any element, whatever its role, whose accessibility label starts with `prefix` and, when `needle` is given, contains it.
    /// An empty needle is left out of the predicate: `CONTAINS ""` matches nothing.
    func element(labelPrefix prefix: String, containing needle: String? = nil) -> XCUIElement {
        var format = "label BEGINSWITH %@"
        var arguments = [prefix]
        if let needle {
            format += " AND label CONTAINS %@"
            arguments.append(needle)
        }
        let predicate = NSPredicate(format: format, argumentArray: arguments)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    func require(_ element: XCUIElement, within seconds: TimeInterval = 15, _ message: String) {
        XCTAssertTrue(element.waitForExistence(timeout: seconds), message)
    }
}
