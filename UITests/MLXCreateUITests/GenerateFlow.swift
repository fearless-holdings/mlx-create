import XCTest

/// What the generate flow leaves behind for the restore flow to compare against.
struct GeneratedImage {
    let prompt: String
    let token: String
    let seed: String
    let size: String
}

extension SmokeSession {
    var promptField: XCUIElement { app.textViews["Prompt"] }
    var seedField: XCUIElement { app.textFields["Seed"] }
    var generateButton: XCUIElement { app.buttons["Generate"] }

    /// The Size popup is the only pop-up button whose value reads like "1024 × 1024".
    var sizePicker: XCUIElement {
        app.popUpButtons.matching(NSPredicate(format: "value CONTAINS %@", "×")).firstMatch
    }

    func seedPolicy(_ name: String) -> XCUIElement { app.radioButtons[name] }

    func setPrompt(_ text: String) {
        promptField.click()
        promptField.typeKey("a", modifierFlags: .command)
        promptField.typeText(text)
    }

    func setSeed(_ text: String) {
        seedField.click()
        seedField.typeKey("a", modifierFlags: .command)
        seedField.typeText(text)
        seedField.typeKey(.return, modifierFlags: [])
    }

    /// The generate flow: launch with the model installed, generate one image with a known prompt and seed, and see it on the canvas and in the gallery.
    func runGenerateFlow() -> GeneratedImage {
        let token = String(UUID().uuidString.prefix(6)).lowercased()
        let prompt = "smoke \(token) a red apple on a wooden table"
        let seed = "424242"

        step("Launch with the model installed") {
            launchOnBuiltInDisplay()
            require(element(labelPrefix: "Model: "), within: 90, "the Model chip never appeared: the app did not load the installed model")
        }
        step("Type the prompt") {
            setPrompt(prompt)
            XCTAssertEqual(promptField.value as? String, prompt, "the Prompt field did not take the typed text")
        }
        step("Fix the seed") {
            seedPolicy("Fixed").click()
            require(seedField, "the Seed field did not appear after choosing Fixed")
            setSeed(seed)
            XCTAssertEqual(seedField.value as? String, seed, "the Seed field did not take the typed seed")
        }
        let size = step("Read the size") { () -> String in
            require(sizePicker, "the Size picker is missing")
            return sizePicker.value as? String ?? ""
        }
        XCTAssertFalse(size.isEmpty, "the Size picker has no value")

        step("Press Generate and see progress") {
            XCTAssertTrue(generateButton.isEnabled, "Generate is disabled with a prompt and an installed model")
            generateButton.click()
            require(element(labelPrefix: "Generation progress"), within: 120, "no generation progress appeared after pressing Generate")
        }
        step("The image reaches the canvas and the gallery") {
            require(
                element(labelPrefix: "Selected image: ", containing: token), within: 240, "the generated image never reached the canvas")
            require(element(labelPrefix: "Image: ", containing: token), within: 30, "the generated image never reached the gallery")
        }
        return GeneratedImage(prompt: prompt, token: token, seed: seed, size: size)
    }
}
