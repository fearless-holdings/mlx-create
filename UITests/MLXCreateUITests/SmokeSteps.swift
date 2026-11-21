import CoreGraphics
import XCTest

/// One ordered smoke run (KTD5): a single app launch, named steps, and a `.keepAlways` screenshot after every step (KTD8).
/// The runner (`scripts/gui-smoke/run_smoke.py`) owns the throwaway home: the test runner is sandboxed, so this only reads it.
@MainActor
final class SmokeSession {
    let app = XCUIApplication()
    private let testCase: XCTestCase
    private var stepCount = 0
    private var currentStep = "00 before the first step"

    init(testCase: XCTestCase) throws {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["MLXC_SMOKE_HOME"] ?? ""
        let modelID = environment["MLXC_SMOKE_MODEL_ID"] ?? ""
        try XCTSkipIf(
            home.isEmpty || modelID.isEmpty,
            "Run through scripts/gui-smoke/run_smoke.py: it builds the throwaway home and passes the model id")
        self.testCase = testCase
        // CFFIXED_USER_HOME redirects the library, models and engine. The marker pair keeps the home in the app's command
        // line for path-based cleanup; a bare path argument would be opened as a document and suppress the window. The
        // persistence flag stops macOS restoring zero windows from an earlier session (docs/lld/gui-smoke.md section 4).
        app.launchEnvironment["CFFIXED_USER_HOME"] = home
        // `-mainWindowMode canvas` forces the Canvas layout: since D54 a fresh defaults read opens Chat mode, and
        // these flows drive the three-panel workspace.
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-MLXCSmokeHome", home, "-mainWindowMode", "canvas",
        ]
        // A failed assertion stops the test before the step can screenshot itself, so the end state is captured here, named
        // after the step that was running. The runner shows it as the last screenshot.
        testCase.addTeardownBlock { [self] in
            if testCase.testRun?.hasSucceeded == false {
                attachScreenshot(named: "\(currentStep) FAILED")
            }
        }
    }

    /// Runs `body` as a named activity and attaches a screenshot of the window afterwards.
    func step<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        stepCount += 1
        let label = String(format: "%02d %@", stepCount, name)
        currentStep = label
        return try XCTContext.runActivity(named: label) { _ in
            let result = try body()
            attachScreenshot(named: label)
            return result
        }
    }

    /// Launches the app and waits until its window is on the built-in display, the one screen every run is sure to have.
    ///
    /// macOS opens the window on whichever display it picks, which depends on the monitors plugged in, and a window on an
    /// external display made `window.screenshot()` fail ("Failed to create screenshot"). XCUITest cannot move a window (a
    /// title-bar drag leaves the frame unchanged) and this runner is sandboxed, so `run_smoke.py` moves it through System
    /// Events; this only checks that it happened, so a failure names the cause instead of an opaque screenshot error.
    func launchOnBuiltInDisplay() {
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 30) else { return }
        guard let display = Self.builtInDisplayBounds() else {
            XCTFail("No built-in display is active (lid closed?): the smoke run needs the laptop's own screen")
            return
        }
        let onBuiltIn = NSPredicate { _, _ in display.contains(window.frame) }
        let settled = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: onBuiltIn, object: nil)], timeout: 20)
        XCTAssertEqual(
            settled, .completed,
            "the window is not on the built-in display (frame \(window.frame), display \(display)); run_smoke.py moves it through System Events, so use the runner and allow it Accessibility"
        )
    }

    /// Bounds of the built-in display in the global top-left-origin space XCUIElement frames use.
    private static func builtInDisplayBounds() -> CGRect? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }.map { CGDisplayBounds($0) }
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
