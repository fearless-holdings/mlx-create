# S03 · Model chip: move it to the toolbar and name the exact model

| | |
|---|---|
| Tag | STRUCTURE |
| Severity (Nielsen 0–4) | 2, minor: it takes 36 pt of the busiest panel, and with two models of one family installed the chip cannot tell them apart |
| Frequency | Every session |
| Heuristics | H4 Consistency and standards; H2 Match between system and the real world; H8 Aesthetic and minimalist design |
| User task | (a) first image, (b) tweak and generate again |
| Strategy metric | Nothing to learn; time to first kept image (vertical room for the prompt) |
| HLD decisions | No D* change. It implements what HLD §10 already shows: the wireframe puts `[Qwen-Image 4bit ●]` at the trailing end of the toolbar, and the list says "Model chip with a fit badge". D33 mentions "a LoRA library sheet beside the model chip" |
| Size | S |
| Depends on | none |

## Evidence

- Screenshots: `screens/03a-ready-empty-hint_small_light.png` (the chip is a full-width 279×24 pt row between Enhance and the settings), `screens/13-model-chip-popover_small_light.png`.
- Code: `Sources/MCApp/ModelChip.swift`, `ModelChip.body` and `ModelChip.title(for:)`, which returns `installed.family?.displayName`, so "FLUX.2 klein" for both klein 4B and klein 9B. The chip is placed by `GenerationPanel.layout(promptFillsHeight:)`. `MainWindow.body` has a single `ToolbarItem(placement: .navigation)` (the collection menu), and the trailing toolbar area is empty.
- The type's own doc comment says "Toolbar model chip", but the view is not in the toolbar.
- HIG, Toolbars: "Trailing edge. The trailing edge contains important items that need to remain available … Items on the trailing edge remain visible at all window sizes."
- Comparison: Image Playground and Photos put whole-window controls in the toolbar and keep the content area for content (README, Comparable apps).

## Current behavior

The chip is a bordered button with `Label(chipTitle, systemImage: "cpu")`, a spacer and `chevron.up.chevron.down`, stretched to the panel width. It opens a popover listing available models, then unavailable ones, then "Browse models…". The title is the family name. There is no fit badge.

## Target behavior

- The chip is a `ToolbarItem(placement: .primaryAction)` in `MainWindow`: the trailing edge, always visible.
- Its label is `Label(title, systemImage: "cpu")` with `.labelStyle(.titleAndIcon)`, with no stretching and no chevron (the toolbar button style shows it as a button).
  - `title` is the catalog model's `name` when the signed catalog lists the installed model's repo (for example "FLUX.2 klein 4B"). Otherwise it is `ModelChip.title(for:)`, the family name.
  - When the catalog model's fit band for this Mac is `.tight`, the label is followed by `Image(systemName: "exclamationmark.triangle.fill")` in `.orange` and the help text reads "Tight fit on this Mac: other apps may need to be closed". With `.exceeds`, the same symbol and the help "Needs more memory than this Mac has". With `.comfortable` or `.unknown`, there is no badge.
- `.accessibilityLabel("Model: \(title)")` stays. The smoke suite finds the chip by the prefix "Model: ".
- Popover rows use the same `title`. Under each available row, show the speed estimate when one exists: `model.browser.estimates[installed.id]?.label` in `.caption`, `.secondary`.
- `GenerationPanel` no longer shows the chip.

## Edit steps

1. In `Sources/MCApp/Models/ModelBrowserModel.swift`, add to `ModelBrowserModel` (next to `rows(of:)`):

   ```swift
   /// The catalog row whose model is published under `repo` (the engine's model id), if the catalog lists one.
   func row(forRepo repo: String) -> ModelBrowserRow? {
       rows.first { $0.model?.repo == repo }
   }
   ```

2. In `Sources/MCApp/ModelChip.swift`:
   - Add an instance helper:

     ```swift
     /// The catalog's model name ("FLUX.2 klein 4B") when the catalog lists this model, else the family name.
     private func title(_ installed: InstalledModel) -> String {
         model.browser.row(forRepo: installed.id)?.title ?? Self.title(for: installed)
     }
     ```

   - Change `chipTitle` to use `title(selected)` instead of `Self.title(for: selected)`.
   - Replace the `label:` closure of the main `Button` with:

     ```swift
     HStack(spacing: 6) {
         Label(chipTitle, systemImage: "cpu")
             .labelStyle(.titleAndIcon)
         if let fit = selectedFit, fit == .tight || fit == .exceeds {
             Image(systemName: "exclamationmark.triangle.fill")
                 .foregroundStyle(.orange)
                 .accessibilityLabel(fit == .tight ? "Tight fit" : "Needs more memory than this Mac has")
         }
     }
     ```

     Add `private var selectedFit: FitBand? { model.selectedModel.flatMap { model.browser.row(forRepo: $0.id)?.fit } }`. `FitBand` lives in `MCCatalog`, so add `import MCCatalog` to the file.
   - Change `.help("Choose the image model")` to `.help(helpText)`, where `helpText` is "Tight fit on this Mac: other apps may need to be closed" for `.tight`, "Needs more memory than this Mac has" for `.exceeds`, and "Choose the image model" otherwise.
   - In `modelList`, replace `Text(Self.title(for: installed))` in the available rows with:

     ```swift
     VStack(alignment: .leading, spacing: 1) {
         Text(title(installed))
         if let estimate = model.browser.estimates[installed.id] {
             Text(estimate.label)
                 .font(.caption)
                 .foregroundStyle(.secondary)
         }
     }
     ```

     Use `title(row.model)` in the unavailable rows and their accessibility label.
   - Keep `static func title(for:)` unchanged: `LoRALibraryView`, `CivitaiBrowseView` and others call it for family wording ("Compatible with FLUX.2 klein").
3. In `Sources/MCApp/MainWindow.swift`, inside `.toolbar { … }`, after the existing `ToolbarItem(placement: .navigation)`, add:

   ```swift
   ToolbarItem(placement: .primaryAction) {
       ModelChip(model: model)
   }
   ```

4. In `Sources/MCApp/GenerationPanel.swift`, in `layout(promptFillsHeight:)`, delete the line `ModelChip(model: model)`.
5. Format every touched file with `swift format format --in-place --configuration .swift-format <file>`.

## Do not touch

- The popover's content order, the rescan on open (`refreshModels()`), and the "Browse models…" entry.
- `ModelChip.title(for:)` and its other call sites.
- The accessibility label prefix "Model: ".

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke (`python3 scripts/gui-smoke/run_smoke.py --models "$HOME/Library/Application Support/mlx-create/Models/Weights" --model-id Runpod/FLUX.2-klein-4B-mflux-4bit`) exits 0. Its first step requires an element labelled "Model: …".

With `docs/design-audit/capture-kit.md`, FLUX.2 klein 4B symlinked in, window at 1100×692:

6. In `ax dump`, the element whose `desc` starts with `Model: ` is a descendant of `AXToolbar`, and its `desc` is exactly `Model: FLUX.2 klein 4B`. No element under the left panel's `AXGroup/AXHostingView` has a `desc` starting with `Model: `.
7. The toolbar chip's frame is fully inside the window at 1100×692 and at 1680×1050.
8. Captures `S03_small_light.png` and `S03_small_dark.png` are attached to the PR.
