import XCTest

/// The Chat-mode flow (D54): launch into Chat, one turn, the finished tile opened large, a follow-up turn, then the
/// mode switcher. It needs the agent pack: `--agent-model-id` links it into the throwaway home, and without it
/// `SmokeSession(mode: .chat)` skips — the runner then reports NOT RUN.
extension SmokeSession {
    /// The chat input, found by its placeholder so the gallery's search field can never match.
    var chatField: XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "placeholderValue BEGINSWITH %@ OR (label BEGINSWITH %@ AND (elementType == %ld OR elementType == %ld))",
                "Describe a picture", "Describe a picture", XCUIElement.ElementType.textField.rawValue,
                XCUIElement.ElementType.textView.rawValue)
        ).firstMatch
    }

    /// Gallery tiles carry "Image: <prompt>" labels, whatever the mode.
    var imageTiles: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Image: "))
    }

    /// Any status line a working turn shows, including the once-per-engine-version speed measurement a first send
    /// can wait behind. A SwiftUI `Text` can expose its string as `label` or as `value`, so both are tried.
    var chatStatus: XCUIElement {
        let prefixes = ["Thinking", "Waiting for the queue", "Making", "Looking at the result", "Measuring"]
        let format = prefixes.map { _ in "label BEGINSWITH %@ OR value BEGINSWITH %@" }
            .joined(separator: " OR ")
        return app.staticTexts.containing(
            NSPredicate(format: format, argumentArray: prefixes.flatMap { [$0, $0] })
        ).firstMatch
    }

    /// A static text whose whole string is `text`, read as `label` or `value`.
    func staticText(_ text: String) -> XCUIElement {
        app.staticTexts.containing(
            NSPredicate(format: "label == %@ OR value == %@", argumentArray: [text, text])
        ).firstMatch
    }

    func typeInChat(_ text: String) {
        chatField.click()
        app.typeText(text)
    }

    /// Two equal frame reads 0.3 s apart mean the fold animation is done, so the step screenshot catches a
    /// settled layout rather than a mid-animation composite.
    @discardableResult
    func waitForSettledFrame(_ element: XCUIElement) -> CGRect {
        var last = element.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.3)
            let frame = element.frame
            if frame == last { return frame }
            last = frame
        }
        return last
    }

    /// A button the user can point at: in the AX tree with a laid-out frame. An icon-only button built from a
    /// bare `Image` used to produce a labelled element whose frame was `(inf, inf, 0, 0)` — this catches that.
    func assertHittableButton(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[label]
        XCTAssertTrue(button.exists, "\(label) button is not in the accessibility tree", file: file, line: line)
        XCTAssertTrue(
            button.frame.width > 0 && button.frame.height > 0 && button.frame.origin.x.isFinite,
            "\(label) button has no usable frame: \(button.frame)", file: file, line: line)
    }

    /// The floating chat panel, for the two-thirds-of-the-window geometry assertion when unfurled.
    var chatContainer: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chatContainer").firstMatch
    }

    /// The open large image, named by `SelectedImageView`'s loaded state ("Selected image: …"); it takes the
    /// grid's place while open so no tile can collide. "Loading image: …" never matches, so a hit means shown.
    var shownImage: XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Selected image: ")
        ).firstMatch
    }

    func runChatFlow() {
        step("Launch in Chat mode") {
            launchOnBuiltInDisplay()
            require(chatField, within: 120, "the chat input never appeared: the agent or the image model is not ready")
        }
        step("Send the prompt") {
            // Every icon button is a labelled, laid-out element (the chevron used to resolve to an empty frame).
            // The menu is not an AXButton — a Menu surfaces as a menuButton/popUpButton — so it is found by label.
            for label in ["Show conversation", "Send"] {
                assertHittableButton(label)
            }
            // A Menu's accessibility label lands in `title`, not `label` (its label stays "More").
            let options = app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "label == %@ OR title == %@", "Conversation options", "Conversation options")
            ).firstMatch
            XCTAssertTrue(
                options.exists, "Conversation options is not in the accessibility tree")
            XCTAssertTrue(
                options.frame.width > 0 && options.frame.height > 0,
                "Conversation options has no usable frame")
            // ⇧Return is a line break at the caret, not a send — proven before the real prompt goes in: three
            // arrow-lefts put the caret before "one", so the break must land immediately ahead of it. (Checking
            // only for a contained newline would also pass for the append-at-end fallback.)
            typeInChat("line one")
            for _ in 1...3 { app.typeKey(.leftArrow, modifierFlags: []) }
            app.typeKey(.return, modifierFlags: .shift)
            XCTAssertTrue(
                eventually {
                    (self.chatField.value as? String)?.hasSuffix("\none") == true
                }, "Shift+Return did not break the line at the caret")
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])

            typeInChat("a lighthouse on a cliff at sunset")
            app.typeKey(.return, modifierFlags: [])
            require(chatStatus, within: 60, "no status line appeared after Return")
            // While the turn runs Send becomes Stop; it must be hittable too.
            XCTAssertTrue(
                eventually {
                    let stop = self.app.buttons["Stop"]
                    return stop.exists && stop.frame.width > 0 && stop.frame.height > 0
                }, "the Stop button is missing or has no frame while the turn runs")
        }
        step("The image reaches the gallery") {
            require(imageTiles.firstMatch, within: 300, "the generated tile never appeared")
        }
        step("Open the image large") {
            imageTiles.firstMatch.click()
            require(app.buttons["Close"], "the large image did not open")
        }
        step("Refine with the image open") {
            // The refinement lands while its source is still open large: the large view switches to it (D54/F2).
            require(shownImage, "the open image carries no label")
            let firstLabel = shownImage.label
            typeInChat("make it night")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(
                eventually(within: 300) {
                    self.shownImage.exists && self.shownImage.label != firstLabel
                        && self.app.buttons["Close"].exists
                }, "the refinement did not take the large view over")
            _ = waitForSettledFrame(shownImage)
        }
        step("Close the large image") {
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(eventually { !self.app.buttons["Close"].exists }, "Esc did not close the large image")
            XCTAssertTrue(
                eventually { self.imageTiles.count == 2 }, "expected two gallery tiles")
            // The landed image is highlighted, not selected: nothing may carry an "… selected" status text.
            XCTAssertTrue(
                eventually {
                    self.app.staticTexts.containing(
                        NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "selected", "selected")
                    ).firstMatch.exists == false
                }, "a stale selection survived the new image landing")
        }
        step("Unfurl the history") {
            // Let the large-image close finish animating before clicking — a mid-transition hit point misses.
            waitForSettledFrame(chatContainer)
            // Folded shows only the last two messages, so the first request is off screen until unfurled.
            XCTAssertFalse(
                staticText("a lighthouse on a cliff at sunset").exists,
                "the first request was already visible while folded")
            app.buttons["Show conversation"].click()
            // The lazy stack already materializes the first request once unfurled — no scrolling is needed.
            XCTAssertTrue(
                eventually { self.staticText("a lighthouse on a cliff at sunset").exists },
                "the first request did not appear when unfurled")
            XCTAssertTrue(chatField.exists, "the input vanished when unfurled")
            let container = waitForSettledFrame(chatContainer)
            let window = app.windows.firstMatch.frame
            print("unfurled: container \(container) window \(window)")
            XCTAssertEqual(
                container.height, window.height * 2 / 3, accuracy: 40,
                "the unfurled container is not two thirds of the window: container \(container), window \(window)")
        }
        step("Fold the history") {
            app.buttons["Hide conversation"].click()
            XCTAssertTrue(
                eventually { !self.staticText("a lighthouse on a cliff at sunset").exists },
                "the first request stayed visible when folded back")
            print("folded: container \(waitForSettledFrame(chatContainer))")
        }
        step("Mode switcher") {
            // ⌘2 Canvas (the Prompt field), ⌘3 Gallery (the Model chip is back, the Prompt field is gone), ⌘1 Chat.
            app.typeKey("2", modifierFlags: .command)
            XCTAssertTrue(eventually { self.promptField.exists }, "⌘2 did not open Canvas")
            app.typeKey("3", modifierFlags: .command)
            XCTAssertTrue(
                eventually {
                    self.element(labelPrefix: "Model: ").exists && !self.promptField.exists
                }, "⌘3 did not open the gallery")
            app.typeKey("1", modifierFlags: .command)
            XCTAssertTrue(
                eventually { self.chatField.exists }, "⌘1 did not return to Chat")
        }
    }
}
