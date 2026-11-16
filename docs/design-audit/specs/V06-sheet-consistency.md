# V06 · Sheets: one title style, one inset, two widths

| | |
|---|---|
| Tag | VISUAL |
| Severity (Nielsen 0–4) | 1, cosmetic: every sheet looks a little different, which reads as unfinished |
| Frequency | Every sheet |
| Heuristics | H4 Consistency and standards |
| User task | (a) license and enhancer sheets; (d) LoRA sheets; (f) collection name sheet |
| Strategy metric | Indirect: Apple-like finish |
| HLD decisions | No D* change |
| Size | S |
| Depends on | V01. Do it after I10 (license sheet buttons) and S04 (collection sheet) |

## Evidence

- Screenshots: `screens/05b-license-sheet_small_light.png` (title `.title2.bold()`, inset 24, width 500); `screens/09a-enhancer-install-sheet_small_light.png` (title `.title2.bold()`, inset 24, width 480; the install button is not styled as the default); `screens/10c-shelf-license_small_light.png` (title `.title3.bold()`, inset 20, width 520); `screens/16b-new-collection-sheet_small_light.png` (title `.headline`, inset 20, width 340, no accessibility label on the name field: the `AXTextField` in `screens/ax` has no desc).
- Code: `LicenseSheet`, `EnhancerInstallSheet`, `ShelfLicenseSheet` (`ShelfView.swift`), `CivitaiLicenseSheet` (`CivitaiBrowseView.swift`), `CollectionNameSheet` (`CollectionMenu.swift`). The large sheets (`ModelBrowserView` 680×500 minimum, `LoRALibraryView` 880×620 minimum) use a header row with `.title2.bold()` and padding 16.
- HIG, Sheets: "Use a sheet only when your modal task requires a custom title or custom content presentation … Keep sheet interactions brief."

## Target behavior

| Sheet | Title font | Content inset | Width | Buttons |
|---|---|---|---|---|
| License, shelf license, Civitai license, enhancer install | `.mcSheetTitle` | `MCSpacing.sheet` (20) | `MCSize.sheetStandard` (500) | Trailing: Cancel (`.cancelAction`), then the primary action (`.defaultAction`, `.borderedProminent`) |
| Collection name | `.mcSheetTitle` | `MCSpacing.sheet` | `MCSize.sheetNarrow` (360) | Cancel, then Create or Rename (`.defaultAction`, `.borderedProminent`) |
| Models, LoRAs (large) | `.mcSheetTitle` in the header | header `MCSpacing.section` (16) | unchanged minimums | Done (`.cancelAction`) |

- Vertical rhythm inside small sheets: `VStack(alignment: .leading, spacing: MCSpacing.group)`.
- Enhancer install sheet: "Install" becomes `.borderedProminent`. Its first line explains what the download is for: "Rewrites your prompt for the selected model, so you don't have to learn how each model wants to be prompted." (`.mcBody`, `.primary`), above the model name and size.
- Collection name field: `.accessibilityLabel("Collection name")`.

## Edit steps

1. For each small sheet listed above, set the title `Text` to `.font(.mcSheetTitle)`, the outer `VStack` spacing to `MCSpacing.group`, `.padding(…)` to `MCSpacing.sheet`, and `.frame(width: …)` to the width in the table.
2. `EnhancerInstallSheet.content`, `.ready` case: insert the explanatory `Text` above the model name block. In `buttons`, `.ready` case, add `.buttonStyle(.borderedProminent)` to the Install/Resume button.
3. `CollectionNameSheet.body`: add `.accessibilityLabel("Collection name")` to the `TextField`. Add `.buttonStyle(.borderedProminent)` to the Create/Rename button.
4. `ModelBrowserView` and `LoRALibraryView` headers: set the title font to `.mcSheetTitle` (the same face as today) and keep padding 16 via `MCSpacing.section`.
5. Format the touched files.

## Do not touch

- Sheet content and logic (license text, notices, install flow).
- The large sheets' minimum sizes.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.

With the capture kit, empty home:

5. `ax dump` with each small sheet open: the `AXSheet` width is 500 for the license and enhancer sheets and 360 for the collection sheet. The collection sheet's `AXTextField` has `desc="Collection name"`.
6. Captures `V06_license_light.png`, `V06_enhancer_light.png` and `V06_collection_light.png` are attached. In each, exactly one accent-filled button is visible.

## Resolution

Done in [#47](https://github.com/fearless-holdings/mlx-create/pull/47). The change follows the edit steps. One step was already satisfied: the large Models and LoRAs headers used `.mcSheetTitle` and `MCSpacing.section` at `633e737`, so they were left alone. The license, shelf-license, Civitai-license and enhancer-install sheets now take `MCSize.sheetStandard` (500) with `.mcSheetTitle`, `MCSpacing.group` and the `MCSpacing.sheet` inset; the collection-name sheet takes `MCSize.sheetNarrow` (360). The enhancer install sheet gained the explanatory first line and a `.borderedProminent` Install/Resume; the collection field gained `.accessibilityLabel("Collection name")` and a `.borderedProminent` Create/Rename.

Exercised: `swift build`; `swift test` (296 tests on this branch's pre-V05 base); whole-tree `swift format lint --strict`; `xcodegen generate` + Debug `xcodebuild` (`BUILD SUCCEEDED`); GUI smoke (D50) on 2026-11-16, passed, 13 screenshots in `build/gui-smoke/20261116-134231/`, with `Runpod/FLUX.2-klein-4B-mflux-4bit` symlinked into a throwaway home.

Not exercised: the capture-kit `ax dump` widths and `desc="Collection name"` check, and the three light captures (acceptance 5–6). This shell has no Accessibility grant for per-app UI inspection. The widths and label were checked in code against `MCTokens.swift` (`sheetStandard` 500, `sheetNarrow` 360) rather than measured in the running app; the GUI smoke drives the generation and restore flows, not sheet layout.
