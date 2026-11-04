import XCTest

extension SmokeSession {
    /// The gallery tile for the generated image.
    func tile(for image: GeneratedImage) -> XCUIElement {
        element(labelPrefix: "Image: ", containing: image.token)
    }

    /// Polls `condition` until it holds or `seconds` pass. XCUITest queries are synchronous, so this just sleeps between them.
    func eventually(within seconds: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    func isSelected(_ segment: XCUIElement) -> Bool {
        "\(segment.value ?? "")" == "1"
    }

    /// Picks the first Size menu entry that differs from the current one.
    func chooseAnotherSize() {
        let current = sizePicker.value as? String ?? ""
        sizePicker.click()
        let entries = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "×"))
        for index in 0..<entries.count {
            let entry = entries.element(boundBy: index)
            if entry.title != current {
                entry.click()
                return
            }
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTFail("the Size menu offers no size other than \(current)")
    }

    /// The restore flow: on the image the generate flow made, "Reuse prompt" and "Reuse all settings" put the recorded values back.
    /// Every readback starts from a composer that differs from the value being restored, so a restore that does nothing fails.
    func runRestoreFlow(_ image: GeneratedImage) {
        let changedPrompt = "restore check, not the original prompt"
        let changedSeed = "999999"

        step("Change prompt, seed, seed policy and size") {
            showMoreOptions()
            setPrompt(changedPrompt)
            XCTAssertEqual(promptField.value as? String, changedPrompt, "the Prompt field did not take the changed text")
            seedPolicy("Fixed").click()
            require(seedField, "the Seed field did not appear after choosing Fixed")
            setSeed(changedSeed)
            XCTAssertEqual(seedField.value as? String, changedSeed, "the Seed field did not take the changed seed")
            chooseAnotherSize()
            XCTAssertNotEqual(sizePicker.value as? String, image.size, "the size did not change")
            seedPolicy("Random").click()
            XCTAssertTrue(isSelected(seedPolicy("Random")), "the seed policy did not switch to Random")
        }
        step("Reuse prompt from the tile menu") {
            require(tile(for: image), "the gallery tile for the generated image is missing")
            tile(for: image).rightClick()
            let reusePrompt = app.menuItems["Reuse prompt"]
            require(reusePrompt, "the tile menu has no Reuse prompt item")
            reusePrompt.click()
            XCTAssertTrue(eventually { promptField.value as? String == image.prompt }, "Reuse prompt did not restore the original prompt")
            XCTAssertTrue(isSelected(seedPolicy("Random")), "Reuse prompt changed the seed policy, which it must leave alone")
            XCTAssertNotEqual(sizePicker.value as? String, image.size, "Reuse prompt changed the size, which it must leave alone")
        }
        step("Change the prompt again") {
            setPrompt(changedPrompt)
            XCTAssertEqual(promptField.value as? String, changedPrompt, "the Prompt field did not take the changed text")
        }
        step("Reuse all settings") {
            // ⌘R is the Image ▸ Reuse All Settings menu command; the tile menu item is the fallback.
            app.typeKey("r", modifierFlags: .command)
            if eventually(within: 5, { promptField.value as? String == image.prompt }) {
                XCTContext.runActivity(named: "Restored through the ⌘R shortcut") { _ in }
            } else {
                XCTContext.runActivity(named: "⌘R did not fire; used the tile menu instead") { _ in }
                tile(for: image).rightClick()
                let reuseAll = app.menuItems["Reuse all settings"]
                require(reuseAll, "the tile menu has no Reuse all settings item")
                reuseAll.click()
            }
            XCTAssertTrue(eventually { promptField.value as? String == image.prompt }, "Reuse all settings did not restore the prompt")
            XCTAssertTrue(eventually { isSelected(seedPolicy("Fixed")) }, "Reuse all settings did not set the seed policy to Fixed")
            XCTAssertEqual(seedField.value as? String, image.seed, "Reuse all settings did not restore the seed")
            XCTAssertEqual(sizePicker.value as? String, image.size, "Reuse all settings did not restore the size")
        }
    }
}
