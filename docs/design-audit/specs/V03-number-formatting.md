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
  - `Sources/MCApp/Models/ModelBrowserModel.swift`, `fitWarning(needGB:usableGB:)`, and `GenerationPanel.guidanceSection` (the CFG value): the same `String(format: "%.1f", …)`, also always ".".
  - `Sources/MCApp/QueueStripView.swift`: `Text("Step \(step) of \(total)")`. Harmless below 1000, but the same mechanism.
- The smoke suite reads the Size value and the Size menu items through `title CONTAINS "×"`, which still holds after the fix.

## Target behavior

- Pixel sizes are plain integers: "1024 × 1024". Step, batch, saved and import counts keep SwiftUI's locale formatting: steps cap at 100 and batches at 16, so they never group, and grouping is correct for counts. The seed field binds a `String` and is never grouped.
- Decimals follow the user's locale everywhere, with one fraction digit for memory: "about 8,0 GB RAM" in a ","-decimal locale and "about 8.0 GB RAM" in a "."-decimal one.
- LoRA weights keep their locale decimal ("0,75") and are unchanged: they are locale decimals, not identifiers.

## Edit steps

1. `GenerationPanel.sizeSection` (`ComposerSettings` after S02): print the Size picker labels verbatim, `Text(verbatim: "\(size.width) × \(size.height)").tag(size)`, so SwiftUI's localized interpolation cannot group them. No `sizeLabel` helper and no `NumberFormattingTests`: plain Swift interpolation never groups, so such a test would pass on the unfixed code. The permanent guard is in the GUI smoke instead: `runGenerateFlow` asserts the real Size value is two ASCII digit runs around "×" (`GenerateFlow.swift`), which fails on "1.024 × 1.024" in a grouping locale (verified on the unfixed label) and pins no wording.
2. Replace `String(format: "%.1f", …)` with `.formatted(.number.precision(.fractionLength(1)))` at all three sites: `InstallRow.facts(for:)` (`model.ramGB`), `ModelBrowserModel.fitWarning(needGB:usableGB:)` (both figures) and `GenerationPanel.guidanceSection` (the CFG value, keeping the "Default" fallback).
3. Sweep with `rg -n 'Text\("[^"]*\\\((size|progress|job|controls\.steps|image)\.' Sources/MCApp` and convert only a value that can reach 1000. The remaining hits (`Step n of m`, the fixed-steps text, `n of m saved`, the LoRA import progress) cannot, and counts are right to group, so none were converted.
4. Format the touched files.

## Do not touch

- Byte counts (`.byteCount(style: .file)`) and download counts (`downloads.formatted()`): locale grouping is right for them.
- The Size picker's tags (values), only its labels.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0 (it reads the Size value and picks another size from the menu).

With the capture kit, on this Mac: its locale is `en_US@rg=dezzzz` (English, Germany region), which groups with "." and uses "," as the decimal, so no flag is needed and the unfixed build already reproduces the defect. On a Mac in another region, switch the system region to Germany first.

6. `ax dump | grep '×'` shows `value="1024 × 1024"` on the Size pop-up, with no "." between digits.
7. The model browser facts line for FLUX.2 klein 4B reads "… 4,62 GB download · about 8,0 GB RAM …", with the same decimal separator on both numbers.

## Resolution

Done. PR [#23](https://github.com/fearless-holdings/mlx-create/pull/23); commits `302d0b1` (fix), `4fcd603` (GUI-smoke assertion that Size is two plain integers) and `c494588` (after screenshot, `screens/V03_after_small_light.png`). Not exercised in the app: the CFG value (every bundled family ships `guidance` null) and the fit warning.
