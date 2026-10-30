# V03 · Numbers: no grouping in pixel sizes and seeds, one decimal style per screen

| | |
|---|---|
| Tag | VISUAL |
| Severity (Nielsen 0–4) | 2, minor: in the user's locale, the Size control reads "1.024 × 1.024", which looks like "one point zero two four". One row mixes "10,55 GB" with "14.3 GB RAM" |
| Frequency | Every session (the Size control is always visible) for users whose locale groups with "." |
| Heuristics | H2 Match between system and the real world; H4 Consistency and standards |
| User task | (a), (b): reading the size |
| Strategy metric | Nothing to learn |
| HLD decisions | No D* change |
| Size | S |
| Depends on | none |

## Evidence

- Screenshots: `screens/03a-ready-empty-hint_small_light.png` (Size "1.024 × 1.024"); `screens/05-model-browser_small_light.png` ("4-bit (mflux) · 4,62 GB download · about 8.0 GB RAM"); `screens/12b-lora-stack-expanded_large_light.png` (LoRA weight "0,75").
- Code:
  - `Sources/MCApp/GenerationPanel.swift`, `sizeSection` (or `ComposerSettings` after S02): `Text("\(size.width) × \(size.height)")`. SwiftUI's `LocalizedStringKey` interpolation formats `Int` with grouping.
  - `Sources/MCApp/Models/InstallRow.swift`, `facts(for:)`: `String(format: "%.1f", model.ramGB)` (always ".") next to `downloadBytes.formatted(.byteCount(style: .file))` (locale ",").
  - `Sources/MCApp/QueueStripView.swift`: `Text("Step \(step) of \(total)")`. Harmless below 1000, but the same mechanism.
- The smoke suite reads the Size value and the Size menu items through `title CONTAINS "×"`, which still holds after the fix.

## Target behavior

- Pixel sizes, seeds and step counts are plain integers: "1024 × 1024", "Seed 2894417781", "Step 3 of 4".
- Decimals follow the user's locale everywhere, with one fraction digit for memory: "about 8,0 GB RAM" in a ","-decimal locale and "about 8.0 GB RAM" in a "."-decimal one.
- LoRA weights keep their locale decimal ("0,75") and are unchanged: they are locale decimals, not identifiers.

## Edit steps

1. Convert each of these `Int` interpolations to `String(…)` (`Text("\(String(size.width)) × \(String(size.height))")`):
   - the Size picker labels: `GenerationPanel.sizeSection` today, `ComposerSettings` after S02;
   - the fixed-steps text `"\(controls.steps.defaultSteps) steps, set by the model"` (the same files);
   - `CanvasView.StepProgressView`: `"Step \(progress.step) of \(progress.total)"`;
   - `QueueStripView.JobCell`: `"Step \(step) of \(total)"` and `"\(job.savedCount) of \(job.batchCount) saved"`.

   Then check for others with `rg -n 'Text\("[^"]*\\\((size|progress|job|controls\.steps|image)\.' Sources/MCApp` and convert any that print a size, seed, step or count.
2. `InstallRow.facts(for:)`: replace `String(format: "%.1f", model.ramGB)` with `model.ramGB.formatted(.number.precision(.fractionLength(1)))`.
3. Add to the end of `Sources/MCApp/GenerationPanel.swift`:

   ```swift
   extension GenerationPanel {
       /// "1024 × 1024": pixel sizes never take locale grouping (V03).
       static func sizeLabel(_ size: ImageSize) -> String {
           "\(String(size.width)) × \(String(size.height))"
       }
   }
   ```

   Use it for the Size picker labels: `Text(GenerationPanel.sizeLabel(size)).tag(size)`, in `GenerationPanel` or in `ComposerSettings` after S02. Add `Tests/MCAppTests/NumberFormattingTests.swift` (Swift Testing, `@testable import MCApp`, `import MCCatalog`; `ImageSize` lives in `MCCatalog`), asserting `GenerationPanel.sizeLabel(ImageSize(width: 1024, height: 1024)) == "1024 × 1024"`.
4. Format the touched files.

## Do not touch

- Byte counts (`.byteCount(style: .file)`) and download counts (`downloads.formatted()`): locale grouping is right for them.
- The Size picker's tags (values), only its labels.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including `NumberFormattingTests` (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0 (it reads the Size value and picks another size from the menu).

With the capture kit. Launch with a "."-grouping locale by adding `-AppleLocale es_ES` to the `open … --args` line in `launch.sh`, or test on a Mac set to Spanish or German region:

6. `ax dump | grep '×'` shows `value="1024 × 1024"` on the Size pop-up, with no "." between digits.
7. The model browser facts line for FLUX.2 klein 4B reads "… 4,62 GB download · about 8,0 GB RAM …", with the same decimal separator on both numbers.
