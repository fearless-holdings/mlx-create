# S07 · LoRAs: one entry point, and open on the curated list when you have nothing that fits

| | |
|---|---|
| Tag | STRUCTURE |
| Severity (Nielsen 0–4) | 3, major: the curated, no-knowledge path (D43) sits behind the second tab, and a new user lands on an empty "Installed" list |
| Frequency | Every time a user adds a LoRA; first time for every user |
| Heuristics | H8 Aesthetic and minimalist design; H6 Recognition rather than recall; H4 Consistency and standards |
| User task | (d) add a LoRA, including from Civitai |
| Strategy metric | Nothing to learn ("the shelf exists so a first-time user needs no LoRA knowledge", D43); time to a kept image the user wanted |
| HLD decisions | No D* change. D43's shelf, license sheet and add-to-stack-at-tested-scale are unchanged. Only the tab order, the tab labels and the initial tab change. D43's text "a Shelf section of the LoRA library" still describes the content; update the wording to "the Recommended tab (the shelf)" in HLD §10/D43 in the same PR if you want them aligned (wording only) |
| Size | S |
| Depends on | none |

## Evidence

- Screenshots: `screens/10-lora-library-empty_small_light.png` (the sheet opens on Installed: "No LoRAs yet." and an Import… button, with no pointer to the shelf or Civitai), `screens/10b-lora-shelf_small_light.png` (the shelf, second tab), `screens/11-lora-civitai_small_light.png`, `screens/12-lora-stack-collapsed_large_light.png` (the panel shows both a "Library…" link in the section header and an "Add LoRA…" button, and both open the same sheet).
- Code: `Sources/MCApp/LoRASection.swift`, `LoRASection.body` (header `Button("Library…")`, row `Button("Add LoRA…")`). `Sources/MCApp/LoRALibraryView.swift`, `private enum LoRASheetTab` (order installed, shelf, browse; raw values "Installed", "Shelf", "Browse Civitai") and `@State private var tab: LoRASheetTab = .installed`.
- At 1100×640 the LoRA section is below the fold of the scrolling left panel (`03a-ready-empty-hint_small_light.png`); S02 fixes that.
- HIG, Layout: "Order content by relative importance … place the most important items near the top and leading side."

## Current behavior

Two buttons open one sheet. The sheet always opens on Installed. The curated shelf is labelled "Shelf", a word the user has to learn.

## Target behavior

- `LoRASection` has one button, **Add LoRA…**, at the end of the section. The header is plain text "LoRAs" with no link.
- The sheet's segmented control reads, in this order: **Recommended** (the shelf), **Your LoRAs** (installed), **Civitai** (browse).
- Initial tab when the sheet opens:
  1. **Your LoRAs**, when the library holds at least one LoRA that fits the selected model (`model.loraLibrary.contains { $0.fitsSelectedModel }`);
  2. else **Recommended**, when the shelf lists at least one entry for the selected family (`!model.shelf.rows(family: model.loraFamily?.id, includeNSFW: model.civitai.includeNSFW).isEmpty`);
  3. else **Civitai**.
- The empty "Your LoRAs" state offers two more buttons under Import…: **See Recommended LoRAs**, which switches to Recommended (shown only when the shelf has rows for the family), and **Browse Civitai**, which switches to Civitai.
- A drop of `.safetensors` files on the panel or sheet still imports as today (`LoRADrop`).

## Edit steps

1. `Sources/MCApp/LoRASection.swift`, `LoRASection.body`: replace the `header:` closure with `header: { Text("LoRAs") }`. Leave the `if model.loraAddEnabled { Button("Add LoRA…") { … } }` row as it is.
2. `Sources/MCApp/LoRALibraryView.swift`:
   - Change `LoRASheetTab` to:

     ```swift
     private enum LoRASheetTab: String, CaseIterable, Identifiable {
         case shelf = "Recommended"
         case installed = "Your LoRAs"
         case browse = "Civitai"

         var id: Self { self }
     }
     ```

   - Replace `@State private var tab: LoRASheetTab = .installed` with `@State private var tab: LoRASheetTab` and add an initializer:

     ```swift
     init(model: AppModel) {
         self.model = model
         _tab = State(initialValue: Self.initialTab(model))
     }

     /// Your LoRAs when something there fits the selected model; else the curated shelf when it has entries; else Civitai.
     private static func initialTab(_ model: AppModel) -> LoRASheetTab {
         if model.loraLibrary.contains(where: \.fitsSelectedModel) { return .installed }
         let shelfRows = model.shelf.rows(family: model.loraFamily?.id, includeNSFW: model.civitai.includeNSFW)
         return shelfRows.isEmpty ? .browse : .shelf
     }
     ```

     `model` is declared `@Bindable var model: AppModel`. With an explicit `init`, assign it as `self.model = model`, as shown. If the compiler rejects that, use `_model = Bindable(model)`.
   - The `switch tab` in `body` lists `.installed`, `.shelf` and `.browse`. Keep all three cases; only the enum order and labels changed.
   - In `emptyState`, after `importButton`, add:

     ```swift
     HStack(spacing: 12) {
         if !model.shelf.rows(family: model.loraFamily?.id, includeNSFW: model.civitai.includeNSFW).isEmpty {
             Button("See Recommended LoRAs") { tab = .shelf }
         }
         Button("Browse Civitai") { tab = .browse }
     }
     ```

   - Change the segmented control's `.frame(width: 380)` to `.frame(width: 360)`. The new labels are shorter.
3. Format the touched files.

## Do not touch

- `ShelfView`, `ShelfModel.pick`, the shelf license sheet and the tested scale (D43).
- `CivitaiBrowseView` behavior (S08 is separate and needs an HLD change).
- The NSFW opt-in (`civitaiIncludeNSFW`) and blur rules (D15).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0 (`python3 scripts/gui-smoke/run_smoke.py --models "$HOME/Library/Application Support/mlx-create/Models/Weights" --model-id Runpod/FLUX.2-klein-4B-mflux-4bit`).

With the capture kit, FLUX.2 klein 4B symlinked in, **no** LoRA imported, `civitaiIncludeNSFW` false:

6. `ax dump`: no `AXLink` "Library…" anywhere; exactly one `AXButton` "Add LoRA…" in the left panel.
7. Press Add LoRA… (`ax press <pid> "=Add LoRA…"`). In the sheet, `AXRadioButton` "Recommended" has `value="1"` (selected), and the radio buttons appear in the order Recommended, Your LoRAs, Civitai (by frame x).
8. Add the shelf entry (Add to stack, accept the license, Download and add), close and reopen the sheet: "Your LoRAs" is now selected.
9. Captures `S07_sheet_small_light.png` and `S07_panel_small_light.png` are attached to the PR.
