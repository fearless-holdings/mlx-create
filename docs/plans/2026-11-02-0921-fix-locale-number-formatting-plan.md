---
title: Locale-Correct Number Text - Plan
type: fix
date: 2026-11-02
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Locale-Correct Number Text - Plan

## Goal Capsule

- **Objective:** In any region setting, a user reads the numbers in mlx-create the way the rest of macOS writes them: an image size reads "1024 × 1024", never "1.024 × 1.024", and every decimal on one screen uses the same separator.
- **Means:** Print pixel sizes verbatim, and format the three remaining memory and guidance decimals with the locale-aware number style instead of `String(format:)` (KTD1, KTD2).
- **Authority:** `docs/design-audit/specs/V03-number-formatting.md` carries the finding and acceptance checks. This plan overrides its edit steps where KTD1 and KTD3 say so. `docs/HLD.md` stays untouched; no `D*` entry changes.
- **Execution profile:** One small change across three Swift files plus the V03 spec doc in one PR, then a live check on the real app in a grouping locale. The unfixed baseline is taken before any edit (U2 steps 1 to 3).
- **Stop conditions:** Stop and report if the baseline run shows no "1.024" on this Mac under any locale tried; then the finding is not reproduced and nothing is called fixed. Do not widen into the other audit specs.
- **Who finishes:** The implementer ships it, including the live check. A built Debug app, a quit mlx-create, and Developer Mode are prerequisites for the GUI smoke.

## Product Contract

### Summary

Make every number the app prints follow the user's locale correctly: pixel sizes are plain integers, and the memory and guidance decimals use the locale's separator with one fraction digit. Byte counts, download counts and LoRA weights already behave and stay as they are.

### Problem Frame

On this Mac the Size control reads "1.024 × 1.024", which looks like "one point zero two four". SwiftUI formats an `Int` inside a `Text("\(…)")` interpolation as a localized number, so any region that groups thousands adds a separator to a pixel dimension. The Size control is always visible, so for users in grouping regions it is a paper cut in every session.

The same screens also mix decimal styles. The model browser's facts line prints "4,62 GB download" (locale) beside "about 8.0 GB RAM" (always a dot), because `String(format:)` ignores the locale. The audit saw the first; code reading found the same defect in two more places (the browser's fit warning and the CFG value), which the spec's step list did not name.

### Requirements

**Pixel sizes**

- R1. Each Size picker entry reads as two plain integers around " × ", with no grouping separator in any locale.

**Decimals**

- R2. The model browser's facts line prints memory with one fraction digit in the user's decimal separator, matching the separator of the download size beside it.
- R3. The model browser's "may not run" fit warning prints both memory figures the same way.
- R4. The CFG value in the composer prints in the user's decimal separator with one fraction digit.

**Unchanged**

- R5. Byte counts, download counts, LoRA weights, step and batch counts, the seed field, and everything written to PNG metadata or sent to the engine keep their current output.
- R6. The smoke contract holds: the Size pop-up's value and menu items still contain "×", and no other control name changes.

### Scope Boundaries

- Considered and not built: converting `Step \(n) of \(m)`, `\(n) of \(m) saved`, the fixed-steps text and the batch label to verbatim strings, as the spec lists. Steps cap at 100 and batches at 16, so grouping can never appear. Evidence that would change the call: a family whose step range reaches 1000.
- Considered and not built: ungrouping gallery counts such as "Working on 1,204 of 5,000". Grouping is correct for counts.
- Considered and not built: a `sizeLabel` helper and its test (KTD3).
- Seeds are unaffected today: the seed field binds a `String`, and no view interpolates a seed number.
- Other audit specs are not part of this plan. S02 will move the Size control into `ComposerSettings`; the verbatim size label travels with that line.

## Planning Contract

### Key Technical Decisions

- KTD1. **Print the size label with `Text(verbatim:)`.** It bypasses the localized-key interpolation that groups, so the picker entry is exactly the two integers. The spec's alternative, wrapping each side in `String(…)` and adding a `GenerationPanel.sizeLabel` helper, adds a symbol that only a test would call (KTD3). Governs R1.
- KTD2. **Use `Double.formatted(.number.precision(.fractionLength(1)))` for the three `String(format: "%.1f", …)` sites.** This is the style `LoRASection.weightText` already uses, and it follows `Locale.current`, as `.byteCount(style: .file)` does for the neighbouring size. No shared helper: three one-line call sites do not earn one. Governs R2, R3, R4.
- KTD3. **No unit test; the GUI smoke guards the Size label instead.** The spec's `NumberFormattingTests` asserts `sizeLabel(1024×1024) == "1024 × 1024"`. Plain Swift string interpolation never groups, so that assertion passes on the unfixed code and pins nothing; the defect only exists inside SwiftUI's localized `Text`. The decimal sites call the platform's locale formatter and are private view or model text with no locale seam. The Size label is different: the GUI smoke reads its real accessibility value, so `runGenerateFlow` asserts two ASCII digit runs around "×" (no wording pinned), which fails on a grouping locale when the label regresses. Code review found the smoke asserted only non-empty; the new assertion was shown to fail on the unfixed label ("1.024 × 1.024") and pass on the fix. The decimal sites stay proven by the live check in U2 only.

### Assumptions

- This Mac's own locale reproduces the defect, verified 2026-11-02: `defaults read -g AppleLocale` is `en_US@rg=dezzzz` (English language, Germany region; languages `en-US`, `es-DE`), and `Locale.current` on it formats `1024` as "1.024" and `8.0` at one fraction digit as "8,0". So the baseline needs no override: launch the app normally. Only if a launch somehow shows another locale, pass `-AppleLocale en_US@rg=dezzzz` (the machine's exact identifier, which is `en_DE` in shorthand) and first confirm it takes effect: the audit found the `-AppleInterfaceStyle` launch argument inert on this macOS, so a locale override may be too. The app itself needs no runtime fallback locale: SwiftUI and Foundation format with the user's `Locale.current`, `project.yml` declares no localizations, and this plan adds none.

## Implementation Units

### U1. Locale-correct numbers in the UI

- **Goal:** The Size picker entries and the three decimal sites read correctly in any locale.
- **Requirements:** R1, R2, R3, R4, R5, R6
- **Dependencies:** U2 steps 1 to 3 (the unfixed baseline) are taken before the first edit.
- **Files:**
  - `Sources/MCApp/GenerationPanel.swift` (modify: `sizeSection`, `guidanceSection`)
  - `Sources/MCApp/Models/InstallRow.swift` (modify: `facts(for:)`)
  - `Sources/MCApp/Models/ModelBrowserModel.swift` (modify: `fitWarning(needGB:usableGB:)`)
- **Approach:**
  1. Size picker entry: `Text(verbatim: "\(size.width) × \(size.height)")` (KTD1).
  2. Facts line: format `model.ramGB` with the one-decimal number style (KTD2).
  3. Fit warning: format `needGB` and `usableGB` the same way (KTD2).
  4. CFG value: format `model.guidance` the same way, keeping the "Default" fallback (KTD2).
  5. Re-run the spec's sweep for other pixel-size, seed or step text that reaches a `Text` through `\(…)` (`rg -n 'Text\("[^"]*\\\((size|progress|job|controls\.steps|image)\.' Sources/MCApp`). Convert only a value that can reach 1000.
- **Patterns to follow:** `LoRASection.weightText` for the number style; the neighbouring `.formatted(.byteCount(style: .file))` call in `InstallRow.facts(for:)` for the locale behavior to match.
- **Test scenarios:** `UITests/MLXCreateUITests/GenerateFlow.swift` (`runGenerateFlow`, step "Read the size"): the Size value is two non-empty ASCII digit runs around "×". It fails on "1.024 × 1.024" and passes on "1024 × 1024" in a locale that groups; elsewhere it is a harmless structural check. No unit test for the decimal sites (KTD3). The existing `ModelBrowserTests` still only assert `fitWarning != nil`.
- **Verification:** `swift build` and `swift test` pass, lint prints nothing, and the diff touches only the four sites above plus any sweep hit that can reach 1000.

### U2. Prove it on the real app in a grouping locale

- **Goal:** The Size control and the facts line read correctly in the running app, and the smoke contract holds.
- **Requirements:** R1, R2, R6
- **Dependencies:** none for steps 1 to 3 (they run on the unfixed tree, before U1's edits); U1 for steps 4 to 7. Order of work: U2 steps 1 to 3, then U1, then U2 steps 4 to 7.
- **Files:** none modified. Evidence screenshot attached to the PR: `V03_after_small_light.png`.
- **Approach:**
  1. Export the real `com.fearless.mlx-create` defaults first (`docs/design-audit/capture-kit.md` section 2). Every launch writes that real domain, so import them back after the last quit.
  2. Build a throwaway home from the kit's "one model installed" recipe (symlinked FLUX.2 klein 4B), and use the kit's `launch.sh` to launch.
  3. **Baseline first, on the unfixed build, before U1's edits:** build the current tree, copy the Debug app out of `build/` (the U1 rebuild overwrites it), launch, dump the accessibility tree (`ax dump`), and read the Size pop-up value. Open the model browser and read the FLUX.2 klein 4B facts line. Record both readings. Expect "1.024 × 1.024" and mixed separators ("4,62 GB download · about 8.0 GB RAM"). If the Size value reads "1024 × 1024", do not call the finding disproved yet: check the launch picked up the system locale (see Assumptions) before stopping.
  4. After U1, rebuild and repeat under the same locale. Expect "1024 × 1024" with no separator between digits, and "4,62 GB download · about 8,0 GB RAM".
  5. The CFG value has no visible path at all: `guidance` is a family capability and all three bundled families (`krea-2-turbo`, `flux2-klein`, `qwen-image` in `families.json`) ship `"guidance": null`, so R4 is code-only and is reported as not exercised. The fit warning needs a catalog model larger than this Mac's usable memory; exercise it only if an installed or catalog model reaches it without a download, otherwise report it as not exercised too.
  6. Run the GUI smoke (`scripts/gui-smoke/run_smoke.py`) from an Eval Python cell with mlx-create quit.
  7. Import the saved defaults back. Clean up by home path in argv, never by process name, and check for leftover `mlx-serve` and `mlx-create`.
- **Test scenarios:** Test expectation: none -- this unit is the live acceptance run for U1; its pass criteria are the readings in steps 3 and 4 and the smoke result.
- **Verification:** The baseline reproduces the defect, the fixed build shows the corrected Size value and facts line in the same locale, GUI smoke exits 0 (exit 2 is NOT RUN, not a pass), and the screenshot is attached.

## Verification Contract

| Gate | Command or check | Applies to |
|---|---|---|
| Build | `swift build` exits 0 | U1 |
| Tests | `swift test` exits 0 (about 40 s; past 2 minutes it is hung, bisect with `--filter`) | U1 |
| Lint | `git ls-files '*.swift' \| xargs swift format lint --strict --configuration .swift-format` prints nothing | U1 |
| App build | `xcodegen generate`, then `xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **` | U1 |
| Locale reading | Size pop-up reads "1024 × 1024" and the facts line uses one decimal separator, after a baseline that showed the defect | U2 |
| GUI smoke | `python3 scripts/gui-smoke/run_smoke.py --models DIR --model-id ORG/NAME` exits 0, run from an Eval Python cell with mlx-create quit | U2 |

## Definition of Done

- U1 and U2 complete, every gate above passes, and the after screenshot is attached.
- Byte counts, download counts, LoRA weights and the seed field are unchanged in the diff.
- Any decimal site the live check could not reach is named as not exercised in the PR description.
- `docs/design-audit/specs/V03-number-formatting.md` matches what shipped: Edit steps name the two extra decimal sites, the verbatim size label and the smoke assertion, and drop the `sizeLabel` helper and `NumberFormattingTests`; Acceptance item 2 no longer requires `NumberFormattingTests`; the locale line before Acceptance items 6 and 7 names this Mac's own locale (`en_US@rg=dezzzz`, no flag needed) in place of `-AppleLocale es_ES`; the Target behavior line no longer promises "Step 3 of 4"-style step counts as plain integers, since they are left as they are (Scope Boundaries).
- No stray `mlx-serve` or `mlx-create` process is left running, and the real preferences are restored.

## Sources

- `docs/design-audit/specs/V03-number-formatting.md` (finding, evidence, acceptance checks); `docs/design-audit/README.md` section 13 (smoke contract).
- `Sources/MCApp/GenerationPanel.swift` (`sizeSection`, `guidanceSection`), `Sources/MCApp/Models/InstallRow.swift` (`facts(for:)`), `Sources/MCApp/Models/ModelBrowserModel.swift` (`fitWarning`), `Sources/MCApp/LoRASection.swift` (`weightText`, the number style to follow).
- `UITests/MLXCreateUITests/GenerateFlow.swift` (`sizePicker` finds the Size pop-up by `value CONTAINS "×"`).
- `docs/design-audit/capture-kit.md` (throwaway home, `launch.sh`, `ax dump`, defaults export) and `AGENTS.md` Commands (gates and cleanup rules).
