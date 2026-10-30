# S02 · Composer: put the rarely used settings behind "More options"

| | |
|---|---|
| Tag | STRUCTURE |
| Severity (Nielsen 0–4) | 3, major: every session; at the minimum window the prompt is squeezed to 120 pt and the panel scrolls |
| Frequency | Every session, every generation |
| Heuristics | H8 Aesthetic and minimalist design; H6 Recognition rather than recall; H4 Consistency and standards |
| User task | (a) first image, (b) tweak a prompt and generate again |
| Strategy metric | "Nothing to learn", no expert knobs (STRATEGY.md Boundaries); time to first kept image |
| HLD decisions | No D* change. D33 and HLD §10 require the settings to be **inline, with no popover**: an inline disclosure keeps them inline. D13 (seed controls and batch count) stays: seed is one click away and batch stays visible. §8.3's "quality presets (Fast / Balanced / Quality)" for Steps is **not** built here: no family record defines preset step counts, and inventing them risks quality. That stays an open HLD item |
| Size | M |
| Depends on | none. S03 moves the model chip out of this panel and S07 replaces the LoRA header; both are independent of this spec |

## Evidence

- Screenshots: `screens/03a-ready-empty-hint_small_light.png` (at 1100×640 the 108 pt prompt sits above 300 pt of Seed, Size and Steps, and the LoRA section is cut off), `03a-ready-empty-hint_large_light.png`, `06-populated-gallery_large_light.png`.
- Code: `Sources/MCApp/GenerationPanel.swift`: `GenerationPanel.settings`, `seedSection`, `sizeSection(_:)`, `stepsSection(_:)`, `guidanceSection(_:)` and `layout(promptFillsHeight:)`.
- Measured with `ax dump` (`screens/ax/ax-ready.txt`): the prompt `AXTextArea` is 280×121 pt, and the left panel holds an `AXScrollBar` (the short layout of `ViewThatFits` is in use). The panel has 13 interactive elements at rest: Prompt, Recent prompts, Enhance, Model chip, 3 seed segments, Size, Steps stepper, Library…, Add LoRA…, batch stepper and Generate.
- Each setting appears twice: a grouped `Form` `Section("Size")` header **and** a row label "Size". The same goes for "Seed"/"Seed policy" and "Steps"/"Steps". Form rows start 30 pt to the right of the prompt's leading edge (prompt at x = 12, rows at x = 42).
- All three shipped families are distilled or turbo (`families.json`: klein and Krea default to 4 steps, Qwen Turbo is fixed at 8, none supports guidance or negative prompt). The Steps stepper (1…100) and the Random/Fixed/Increment seed policy are exactly the "rarely used, always on screen" controls the user dislikes in Draw Things.
- HIG, Layout: "Use progressive disclosure to make layouts cleaner … Use disclosure triangles, menus, or nested views to reduce how much content to initially display." HIG, Disclosure controls: "Place controls that people are most likely to use at the top … with more advanced functionality hidden by default" and "Provide a descriptive label".
- Comparison (README, Comparable apps): Draw Things' left column shows Model, LoRA, Control, Strength, Seed, Seed Mode and Image Size at once. DiffusionBee keeps every setting behind one "Options" button. Image Playground shows only an aspect-ratio button and a style button.

## Current behavior

`layout(promptFillsHeight:)` renders: prompt editor (min 120 pt), original-prompt box, enhance row, `EnhanceResultCard`, `ModelChip`, then `settings`, a `Form` with `.formStyle(.grouped)` holding `Section("Seed")` (segmented Random/Fixed/Increment, plus a seed field when not Random), `Section("Size")` (Picker), `Section("Steps")` (value text, Stepper, "Use Default" link), `Section("Guidance")` and `Section("Negative prompt")` when the family supports them. Then `LoRASection`.

## Target behavior

```
[ Prompt editor — fills the height left over ]
                       [🕘]  [Enhance]
Size                      [1024 × 1024 ▾]           ← visible at rest
› More options   Seed 424242 · 6 steps               ← one plain button; the summary shows only non-defaults
   (expanded:)
   Seed     [Random | Fixed | Increment]
            [ 424242 ]                                 ← only when not Random
   Steps    4 (default)  [▴▾]   Use Default            ← or "8 steps, set by the model"
   CFG scale ……                                         ← only when the family supports guidance
   Negative prompt [ … ]                                ← only when the family supports it
LoRAs …                                                 ← LoRASection, unchanged here
```

- No `Form` around the settings. Rows use `LabeledContent` inside a `VStack(alignment: .leading, spacing: 10)`, so the row labels align with the prompt's leading edge (the panel's 12 pt padding). The section headers ("Seed", "Size", "Steps", "Guidance", "Negative prompt") are gone; each row label says it once.
- "More options" is a plain `Button` whose label is `chevron.right` (rotated 90° when expanded, `.caption.weight(.semibold)`), then the text "More options", then, when collapsed and any option differs from its default, a `.secondary` summary on the same line.
- Expanded rows sit 16 pt in from the leading edge.
- Expand and collapse animate with `.easeInOut(duration: 0.2)`, or with no animation when `accessibilityReduceMotion` is on.
- Whether "More options" is open is stored in `UserDefaults` under `composerShowsMoreOptions` (default `false`). `applyStoredSettings(_:)` opens it, because it pins a fixed seed the user should see. Gallery Reuse all settings and drop-to-restore of an image whose model is installed both go through that function. A drop of a foreign image (D38, model not installed) does not open it; its seed then shows in the collapsed summary.
- Interactive elements in the left panel at rest, with no image selected and Random seed: at most **10** (Prompt, Recent prompts, Enhance, Model chip, Size, More options, Library…, Add LoRA…, batch, Generate). That drops to 8 after S03 and S07.

## Edit steps

1. **AppModel state.** In `Sources/MCApp/AppModel.swift`, inside `public final class AppModel`:
   - Next to the other defaults keys, add `static let moreOptionsDefaultsKey = "composerShowsMoreOptions"`.
   - Next to `public var batchCount = 1`, add:

     ```swift
     /// Whether the composer's "More options" (seed, steps, CFG, negative prompt) is open. Persisted; Reuse opens it.
     public var showsMoreOptions = false {
         didSet { defaults.set(showsMoreOptions, forKey: Self.moreOptionsDefaultsKey) }
     }
     ```

   - In `init(...)`, right after `self.selectedModelID = defaults.string(forKey: Self.lastUsedModelKey)`, add `self.showsMoreOptions = defaults.bool(forKey: Self.moreOptionsDefaultsKey)`.
   - In `applyStoredSettings(_:)`, as its last line (after `fitComposerToSelectedFamily()`), add `showsMoreOptions = true`.
2. **Summary.** Create `Sources/MCApp/AppModel+MoreOptions.swift`:

   ```swift
   import Foundation

   // The one-line summary "More options" shows while collapsed (docs/design-audit/specs/S02).
   extension AppModel {
       /// The options that differ from their defaults, or nil when all are default. Shown beside the collapsed toggle so a
       /// non-default seed or step count is never hidden.
       var moreOptionsSummary: String? {
           var parts: [String] = []
           let seed = seedText.trimmingCharacters(in: .whitespaces)
           switch seedChoice {
           case .random: break
           case .fixed: parts.append(seed.isEmpty ? "Fixed seed" : "Seed \(seed)")
           case .increment: parts.append(seed.isEmpty ? "Increasing seed" : "Seeds from \(seed)")
           }
           if let steps { parts.append("\(steps) steps") }
           if let guidance { parts.append("CFG \(guidance.formatted(.number.precision(.fractionLength(1))))") }
           if !negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("Negative prompt") }
           return parts.isEmpty ? nil : parts.joined(separator: " · ")
       }
   }
   ```

3. **Settings view.** Create `Sources/MCApp/ComposerSettings.swift` containing `struct ComposerSettings: View` with `@Bindable var model: AppModel`, `let controls: SettingsControls` and `@Environment(\.accessibilityReduceMotion) private var reduceMotion`. Build its `body` as follows:
   - `VStack(alignment: .leading, spacing: 10)`.
   - Size row: `LabeledContent("Size") { sizePicker }`. Move the `Picker("Size", selection: $model.size)` from `sizeSection` unchanged and add `.labelsHidden()` and `.fixedSize()` to it. The visible label comes from `LabeledContent`; the Picker keeps the accessibility title "Size".
   - The toggle button, exactly:

     ```swift
     Button {
         if reduceMotion {
             model.showsMoreOptions.toggle()
         } else {
             withAnimation(.easeInOut(duration: 0.2)) { model.showsMoreOptions.toggle() }
         }
     } label: {
         HStack(spacing: 6) {
             Image(systemName: "chevron.right")
                 .font(.caption.weight(.semibold))
                 .rotationEffect(.degrees(model.showsMoreOptions ? 90 : 0))
                 .accessibilityHidden(true)
             Text("More options")
             if !model.showsMoreOptions, let summary = model.moreOptionsSummary {
                 Text(summary)
                     .foregroundStyle(.secondary)
                     .lineLimit(1)
                     .truncationMode(.tail)
             }
             Spacer(minLength: 0)
         }
         .contentShape(Rectangle())
     }
     .buttonStyle(.plain)
     .accessibilityLabel("More options")
     .accessibilityValue(model.showsMoreOptions ? "expanded" : (model.moreOptionsSummary ?? "collapsed"))
     ```

   - When `model.showsMoreOptions` is true, a `VStack(alignment: .leading, spacing: 10)` with `.padding(.leading, 16)` holding:
     - Seed: `LabeledContent("Seed") { Picker("Seed policy", selection: $model.seedChoice) { Text("Random").tag(SeedChoice.random); Text("Fixed").tag(SeedChoice.fixed); Text("Increment").tag(SeedChoice.increment) }.pickerStyle(.segmented).labelsHidden().fixedSize() }`. When `model.seedChoice != .random`, put the existing seed `TextField` from `seedSection` below it, same placeholder, `.monospacedDigit()` and `.accessibilityLabel`, plus `.textFieldStyle(.roundedBorder)` and `.frame(maxWidth: 160)`.
     - Steps: move the body of `stepsSection(_:)` here unchanged, but drop the `Section("Steps")` wrapper.
     - Guidance: when `controls.guidance` is non-nil, move the body of `guidanceSection(_:)` here unchanged, without its `Section`.
     - Negative prompt: when `controls.showsNegativePrompt`, `LabeledContent("Negative prompt") { TextField("Things to avoid", text: $model.negativePrompt, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder).accessibilityLabel("Negative prompt") }`.
4. **GenerationPanel.** In `Sources/MCApp/GenerationPanel.swift`:
   - Replace the body of `private var settings: some View` with:

     ```swift
     if let controls = model.controls {
         ComposerSettings(model: model, controls: controls)
     } else {
         Text("Choose an available model to see its settings.")
             .frame(maxWidth: .infinity, alignment: .leading)
     }
     ```

     (This drops `.foregroundStyle(.secondary)`: it is the only content of the area, so it is essential text; see V02.)
   - Delete `seedSection`, `sizeSection(_:)`, `stepsSection(_:)` and `guidanceSection(_:)` once their code lives in `ComposerSettings`.
   - Do not change `promptMinHeight`, `layout(promptFillsHeight:)`'s `ViewThatFits`, `bottomRow` or the LoRA drop handling.
5. **Smoke tests.** In `UITests/MLXCreateUITests/GenerateFlow.swift`, inside `extension SmokeSession`:
   - Add:

     ```swift
     var moreOptionsButton: XCUIElement { app.buttons["More options"] }

     /// Opens "More options" when the seed policy is hidden behind it (docs/design-audit/specs/S02).
     func showMoreOptions() {
         if !seedPolicy("Random").exists {
             require(moreOptionsButton, "the More options button is missing")
             moreOptionsButton.click()
         }
         require(seedPolicy("Fixed"), "the seed policy did not appear after opening More options")
     }
     ```

   - In `runGenerateFlow`, make the first line of the "Fix the seed" step `showMoreOptions()`.
   - In `UITests/MLXCreateUITests/RestoreFlow.swift`, make the first line of the "Change prompt, seed, seed policy and size" step `showMoreOptions()`.
6. **Unit test.** Add `Tests/MCAppTests/MoreOptionsTests.swift` with `@Suite struct MoreOptionsTests` containing three tests that use `AppHarness.make()`, `await model.start()` and `await model.refreshModels()`, the way `AppModelTests.reuseRepopulatesPromptModelSizeStepsAndPinsTheSeed` does:
   - `defaultsHaveNoSummary`: a fresh model has `moreOptionsSummary == nil`.
   - `aFixedSeedOrStepsShowInTheSummary`: set `seedChoice = .fixed`, `seedText = "42"` and `steps = 6`. Expect the summary to be non-nil, to contain `"42"` and to contain `"6"`.
   - `reuseOpensMoreOptions`: generate one image (copy the generate-and-wait part of `AppModelTests.generateQueuesAPlaceholderShowsProgressThenSelectsTheResult`), set `model.showsMoreOptions = false`, call `model.reuseSettings(of: image)` and expect `model.showsMoreOptions == true`.
7. Format: `swift format format --in-place --configuration .swift-format` on every file you touched.

## Do not touch

- The accessibility names the smoke suite relies on: text view "Prompt", radio buttons "Random"/"Fixed"/"Increment", text field "Seed", a pop-up button whose value contains "×", button "Generate", and labels beginning "Model: ".
- `LoRASection` (S07), `ModelChip` (S03), `bottomRow`, `EnhanceResultCard`.
- `SettingsControls` and `ModelSelection.controls(for:)`: which controls show stays driven by the family record (HLD §8.3–8.4).
- Do not add quality presets, a sampler, or an "Advanced" section. The word "Advanced" must not appear (AGENTS.md scope guard).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including `MoreOptionsTests` (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke: `python3 scripts/gui-smoke/run_smoke.py --models "$HOME/Library/Application Support/mlx-create/Models/Weights" --model-id Runpod/FLUX.2-klein-4B-mflux-4bit` exits 0. Exit 2 (NOT RUN) is not a pass.

Screenshot and accessibility checks, with `docs/design-audit/capture-kit.md`, one model installed and the window at 1100×692:

6. Before quitting the app, run `defaults delete com.fearless.mlx-create composerShowsMoreOptions` so the run starts collapsed. After launch, `ax dump` shows no `AXScrollBar` under the left panel's `AXGroup/AXHostingView` (x < window x + 320), and the `AXTextArea` "Prompt" is at least **200 pt** tall.
7. In the same dump, count elements under the left panel whose role is `AXButton`, `AXPopUpButton`, `AXRadioButton`, `AXIncrementor`, `AXTextArea`, `AXTextField`, `AXCheckBox`, `AXLink` or `AXSlider`, skipping `AXIncrementArrow`/`AXDecrementArrow` subroles. The count is **≤ 10**. No `AXHeading` reads "Seed", "Size" or "Steps".
8. Press "More options" (`ax press <pid> "=More options"`). Now `AXRadioButton` "Fixed" is present, and its frame's minX is the More options button's minX + 16 ± 2 pt.
9. Captures `S02_small_light.png`, `S02_small_dark.png` and `S02_large_light.png` are attached to the PR. In the small capture, the Size row and More options are visible without scrolling.
