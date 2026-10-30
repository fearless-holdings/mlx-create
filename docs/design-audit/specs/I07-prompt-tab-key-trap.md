# I07 · Prompt: Tab moves focus instead of typing a tab

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 3, major for keyboard and VoiceOver users: keyboard focus cannot leave the prompt (a keyboard trap, WCAG 2.1.2), and every Tab press puts an invisible tab character into the prompt sent to the engine |
| Frequency | Every keyboard user, every session |
| Heuristics | H3 User control and freedom; H4 Consistency and standards (every other Mac text field moves focus on Tab) |
| User task | (a), (b): any keyboard-only use |
| Strategy metric | Nothing to learn |
| HLD decisions | No D* change. HLD §10 "Keyboard first" |
| Size | S |
| Depends on | none |

## Evidence

- Measured with the capture kit (`ax focused` after each key press). Focus is in the prompt. Plain Tab, pressed 14 times: focus stays on `AXTextArea "Prompt"`, and the value gains one `\t` per press. With **Keyboard navigation** turned on (System Settings ▸ Keyboard, `AppleKeyboardUIMode = 2`) and the app relaunched: Tab, pressed 28 times, still never leaves the prompt. ⌃Tab, pressed 16 times: never leaves either.
- Code: `Sources/MCApp/GenerationPanel.swift`, `promptEditor`: a SwiftUI `TextEditor` (an `NSTextView`), with no key handling.
- Verified fix: the handler in step 2, in a scratch SwiftUI app on this Mac (macOS 27.2, Xcode 27.1). Tab moved focus from the `TextEditor` to the next `TextField`, ⇧Tab to the previous one, and the value stayed "ab".
- HIG, Keyboards: "Support Full Keyboard Access when possible." HIG, Accessibility: "Let people use the keyboard alone to navigate and interact with your app."

## Target behavior

- In the prompt editor, Tab moves focus to the next key view and ⇧Tab to the previous one. No tab character is ever inserted.
- ⌥Tab inserts a literal tab, as in macOS text views. This is rarely needed, and keeps the standard escape hatch.
- Return keeps inserting a newline; ⌘↩ keeps generating.

## Edit steps

1. In `Sources/MCApp/GenerationPanel.swift`, add `import AppKit` at the top if it is missing.
2. In `promptEditor`, after `.accessibilityLabel("Prompt")`, add exactly this. It was tested on macOS 27.2: Tab reaches the next field, ⇧Tab the previous one, and nothing is typed. ⇧Tab arrives as the back-tab character U+0019, not as `.tab` with ⇧, so both keys are listed.

   ```swift
   // Tab and ⇧Tab leave the prompt like any other field (no keyboard trap, I07); ⌥Tab still types a tab.
   .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
       if press.modifiers.contains(.option) { return .ignored }
       if press.key == .tab && !press.modifiers.contains(.shift) {
           NSApp.keyWindow?.selectNextKeyView(nil)
       } else {
           NSApp.keyWindow?.selectPreviousKeyView(nil)
       }
       return .handled
   }
   ```

3. Format the file.

## Do not touch

- The prompt's placeholder overlay, accessibility label ("Prompt") and frame logic.
- Any other text field.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0.

Keyboard check with the capture kit (one model installed, default keyboard settings):

6. Bring the app to the front, focus the prompt (`ax focus <pid> AXTextArea "Prompt"`), type `ab` (`osascript -e 'tell application "System Events" to keystroke "ab"'`), press Tab (`key code 48`). `ax focused <pid>` no longer reports `desc=Prompt`, and `ax dump | grep 'desc="Prompt"'` shows `value="ab"` with no `\t`.
7. ⇧Tab (`key code 48 using shift down`) from the next field returns focus to the prompt.
8. Add an XCUITest step to `UITests/MLXCreateUITests/GenerateFlow.swift`, at the end of "Type the prompt":

   ```swift
   promptField.typeKey(.tab, modifierFlags: [])
   XCTAssertEqual(promptField.value as? String, prompt, "Tab typed a character into the prompt instead of moving focus")
   ```

   The GUI smoke run must pass with it.
