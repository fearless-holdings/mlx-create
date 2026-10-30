# I09 · Enhance: say what the buttons do, let Accept be undone, and drop stale provenance

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 2, minor: "Revert" on a card that changed nothing reads as undo; after Accept there is no way back; the "Original prompt" stays after the user writes a different prompt, so the next image's metadata records a wrong original prompt |
| Frequency | Every Enhance; the stale provenance happens whenever a user enhances and then writes something new |
| Heuristics | H3 User control and freedom; H2 Match between system and the real world; H5 Error prevention |
| User task | (b) tweak a prompt and generate again |
| Strategy metric | Nothing to learn; the enhancer is the "expert in the box" track |
| HLD decisions | No D* change. HLD §8.8 names the card's actions "Accept, Revert and Regenerate". This renames two labels; their behavior is unchanged. Update the wording in §8.8 in the same PR. Provenance (KTD7, R17) keeps its meaning: it is dropped only when the prompt no longer derives from the enhancement |
| Size | S |
| Depends on | none |

## Evidence

- Screenshots: `screens/09d-enhance-ready_small_light.png` (Regenerate, Revert, and Accept prominent; Generate prominent too); `screens/09e-enhance-accepted_small_light.png` (the "Original prompt" box after Accept, with no action); `screens/08c-oom-failed-jobs_large_light.png` and `screens/04c-queue-cancelled_small_light.png` (the prompt is now "a paper boat on a puddle, overcast" or "a ceramic vase…", but the box still says "Original prompt: a cozy reading nook by a rainy window").
- Code: `Sources/MCApp/EnhanceResultCard.swift`, `actions` (`Button("Revert")` calls `revertEnhance()`, which only drops the card). `Sources/MCApp/GenerationPanel.swift`, `originalPromptField` (read-only, no action). `Sources/MCApp/AppModel.swift`, `prompt`'s `didSet` drops `originalPrompt` only when the prompt becomes empty. `AppModel+Enhance.swift`, `acceptEnhance()`.
- HIG, Buttons: a button title should "describe what it does"; use title case on macOS.

## Target behavior

- Ready card buttons: **Regenerate** (unchanged), **Discard** (was Revert; same action), **Use This Prompt** (was Accept; same action, still `.borderedProminent`, still disabled while stale).
- Failed card: **Dismiss** and **Try Again** (was Regenerate).
- Original-prompt box (after Use This Prompt): a title row reading "Original prompt", with on its trailing side `Button("Restore")` (`.link`, `.controlSize(.small)`). Restore sets `prompt` back to the original text and clears the provenance.
- Provenance rule: `originalPrompt` is cleared when the prompt becomes empty (as today), **or** when the prompt shares no word of four or more letters with the enhanced text that was accepted. The comparison is case-insensitive and splits on anything that is not a letter or digit. Small edits keep the provenance; writing a different prompt drops it.

## Edit steps

1. `Sources/MCApp/AppModel.swift`:
   - Next to `var originalPrompt: String?`, add `/// The enhanced text the user accepted; the provenance holds while the prompt still derives from it (I09).` followed by `var acceptedEnhancedPrompt: String?`.
   - Replace the `prompt` property's `didSet` body with:

     ```swift
     // Emptying the prompt, or writing one that shares no word with the accepted enhancement, drops the provenance (KTD7, I09).
     if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
         originalPrompt = nil
         acceptedEnhancedPrompt = nil
     } else if originalPrompt != nil, let accepted = acceptedEnhancedPrompt,
         Self.significantWords(prompt).isDisjoint(with: Self.significantWords(accepted))
     {
         originalPrompt = nil
         acceptedEnhancedPrompt = nil
     }
     ```

   - Add to `AppModel`:

     ```swift
     /// Lowercased words of four or more letters or digits: the content words two prompts must share to be related.
     static func significantWords(_ text: String) -> Set<String> {
         Set(
             text.lowercased()
                 .split { !$0.isLetter && !$0.isNumber }
                 .map(String.init)
                 .filter { $0.count >= 4 })
     }
     ```

   - In `applyStoredSettings(_:)` and `reusePrompt(of:)`, after `originalPrompt = …`, add `acceptedEnhancedPrompt = originalPrompt == nil ? nil : prompt`.
2. `Sources/MCApp/AppModel+Enhance.swift`, `acceptEnhance()`: before `prompt = result.prompt`, add `acceptedEnhancedPrompt = result.prompt`. Add:

   ```swift
   /// Puts the text an accepted enhancement replaced back into the prompt, and drops the provenance (I09).
   public func restoreOriginalPrompt() {
       guard let original = originalPrompt else { return }
       originalPrompt = nil
       acceptedEnhancedPrompt = nil
       prompt = original
   }
   ```

3. `Sources/MCApp/AppModel+PromptHistory.swift`, `applyPromptHistoryEntry(_:)`: after `originalPrompt = nil`, add `acceptedEnhancedPrompt = nil`.
4. `Sources/MCApp/EnhanceResultCard.swift`, `actions`: rename `Button("Revert")` to `Button("Discard")` and `Button("Accept")` to `Button("Use This Prompt")`. In the `.failed` case, rename `Button("Regenerate")` to `Button("Try Again")`.
5. `Sources/MCApp/GenerationPanel.swift`, `originalPromptField`: replace `Text("Original prompt").font(.caption).foregroundStyle(.secondary)` with

   ```swift
   HStack {
       Text("Original prompt")
           .font(.caption)
           .foregroundStyle(.secondary)
       Spacer(minLength: 0)
       Button("Restore") { model.restoreOriginalPrompt() }
           .buttonStyle(.link)
           .controlSize(.small)
           .help("Put the original prompt back")
   }
   ```

   The container's `.accessibilityElement(children: .combine)` would swallow the button. Change it to `.accessibilityElement(children: .contain)`, keep `.accessibilityLabel("Original prompt, read only: \(original)")` on the inner `ScrollView` only, and give the button `.accessibilityLabel("Restore original prompt")`.
6. Tests, in `Tests/MCAppTests/EnhanceTests.swift`, following `acceptReplacesThePromptAndRecordsTheTextItReplaced` (it uses `enhancerHarness(chat:)`, `readyKrea(_:prompt:)` and `chatReply(_:)`):
   - `anEditThatKeepsTheEnhancementKeepsTheOriginal`: after accept ("a misty lighthouse at dusk"), set `model.prompt = "a misty lighthouse at dawn"`; `originalPrompt` is still "a lighthouse".
   - `aDifferentPromptDropsTheOriginal`: after accept, set `model.prompt = "a paper boat on a puddle"`; `originalPrompt == nil`.
   - `restoreBringsTheOriginalBack`: after accept, call `model.restoreOriginalPrompt()`; `prompt == "a lighthouse"` and `originalPrompt == nil`.
   Run the existing `EnhanceTests` unchanged; they must still pass.
7. `docs/HLD.md` §8.8: change "with Accept, Revert and Regenerate" to "with Use This Prompt, Discard and Regenerate; after use, Restore puts the original back".
8. Format the touched files.

## Do not touch

- Enhance scheduling (D36), streaming, the stale rule, and the enhancer pack text.
- `originalPrompt` handling in metadata (MCLibrary).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including the three new tests and every existing `EnhanceTests` test (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter EnhanceTests`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.

With the capture kit and the enhancer installed (capture kit §3). If the engine refuses for memory, retry when the Mac is idle.

5. Enhance "a cozy reading nook by a rainy window". The ready card's `ax dump` shows buttons "Regenerate", "Discard" and "Use This Prompt", and no "Revert" or "Accept".
6. Press Use This Prompt, then set the prompt to "a paper boat on a puddle" (`ax setvalue`). `ax dump` no longer shows "Original prompt".
7. Repeat 5 and press Use This Prompt, then press Restore. The prompt is back to "a cozy reading nook by a rainy window".
8. Captures `I09_card_small_light.png` and `I09_original_small_light.png` are attached to the PR.
