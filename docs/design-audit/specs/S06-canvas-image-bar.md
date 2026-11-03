# S06 · Canvas: show what the image is and what you can do with it

| | |
|---|---|
| Tag | STRUCTURE |
| Severity (Nielsen 0–4) | 3, major: keeping an image (export) and building on it (reuse) are hidden behind hover or right-click on a 114 pt thumbnail |
| Frequency | Every kept image |
| Heuristics | H6 Recognition rather than recall; H1 Visibility of system status; H7 Flexibility and efficiency of use |
| User task | (a) first *kept* image, (b) tweak and generate again, (c) find and reuse an old image |
| Strategy metric | Time to first **kept** image |
| HLD decisions | No D* change. The actions are the existing D37 ones (Reveal, Export, Delete to Trash with no confirmation) and Reuse settings, aimed at the canvas image. Export stays a byte copy with metadata (D37) |
| Size | M |
| Depends on | none |

## Evidence

- Screenshots: `screens/03c-first-image-done_small_light.png` and `screens/06-populated-gallery_large_light.png`. The canvas shows the picture and nothing else: no prompt, size, seed or model, and no button. `screens/17-gallery-context-menu_small_light.png` shows the only route to Export: right-click a thumbnail (or hover it and click the 24 pt "…" badge), then choose Export….
- Code: `Sources/MCApp/CanvasView.swift`, `ContentCanvas.body` and `SelectedImageView`. The actions live in `GalleryView.swift`, `ImageCell.actions`, and act on `model.gallerySelection` (`AppModel+GalleryActions.swift`: `exportSelected()`, `revealSelected()`, `deleteSelected()`).
- HIG, Toolbars: "Provide actions that support the main tasks people perform." HIG, The menu bar: a context menu must not be the only way to do something.
- Comparison: Photos puts Share, Favorite, Rotate and Edit in the toolbar of the single-photo view, with the title and metadata above. Image Playground puts Delete, Share and More at the top right of the image view and the prompt as a title above the image. DiffusionBee 1.5.1 shows "Save Image" under the image.

## Current behavior

After a generation the image fills the canvas. To export it, the user must know to right-click the thumbnail in the gallery. To reuse its settings: right-click › Reuse all settings, or ⌘R (S05 makes ⌘R visible in the menu bar).

## Target behavior

Under the image (only when `model.canvasImage` is non-nil, so it stays under the kept image while a followed job runs), inside `ContentCanvas` and above the step bar:

```
a lighthouse on a rocky coast at dusk, warm window light…            [Reuse Settings] [⬆︎ Export…] [📁] [🗑]
1024 × 1024 · FLUX.2 klein · Seed 2894417781
```

- Line 1: the prompt. `.body`, `.primary`, `lineLimit(2)`, `.truncationMode(.tail)`, `.textSelection(.enabled)`, and `.help(image.prompt)` for the full text.
- Line 2: `"\(String(image.width)) × \(String(image.height)) · \(model.displayName(for: image.settings.modelID)) · Seed \(String(image.seed))"`, `.callout`, `.secondary`. Use `String(_:)` for the numbers so they never show grouping separators ("1.024"); see V03.
- Trailing buttons, `HStack(spacing: 8)`, all `.controlSize(.regular)`:
  - `Button("Reuse Settings")`, `.bordered`: `model.reuseSettings(of: image)`.
  - `Button { … } label: { Label("Export…", systemImage: "square.and.arrow.up") }`, `.bordered`: export only this image.
  - `Button { … } label: { Image(systemName: "folder") }`, `.borderless`, `.help("Show in Finder")`, `.accessibilityLabel("Show in Finder")`.
  - `Button(role: .destructive) { … } label: { Image(systemName: "trash") }`, `.borderless`, `.help("Move to Trash")`, `.accessibilityLabel("Move to Trash")`.
- The bar is 12 pt below the image. The text column takes the leftover width (`frame(maxWidth: .infinity, alignment: .leading)`). When the canvas is narrower than 560 pt, the button titles collapse: "Reuse Settings" becomes an icon button (`arrow.uturn.backward`) and "Export…" becomes an icon button (`square.and.arrow.up`), both with `.help` and accessibility labels. Implement this with `ViewThatFits(in: .horizontal)` over the labelled and the icon-only `HStack`.
- Every export, reveal and trash action targets **this** image only. Call `model.selectGalleryImage(image.id, click: .plain)` first, then the D37 action.

## Edit steps

1. In `Sources/MCApp/CanvasView.swift`, add:

   ```swift
   /// The canvas image's prompt, facts and actions (docs/design-audit/specs/S06). Actions target this image only.
   private struct CanvasImageBar: View {
       let model: AppModel
       let image: LibraryImage

       var body: some View {
           HStack(alignment: .top, spacing: 12) {
               VStack(alignment: .leading, spacing: 2) {
                   Text(image.prompt)
                       .font(.body)
                       .lineLimit(2)
                       .truncationMode(.tail)
                       .textSelection(.enabled)
                       .help(image.prompt)
                   Text(facts)
                       .font(.callout)
                       .foregroundStyle(.secondary)
               }
               .frame(maxWidth: .infinity, alignment: .leading)
               ViewThatFits(in: .horizontal) {
                   buttons(labelled: true)
                   buttons(labelled: false)
               }
           }
       }

       private var facts: String {
           "\(String(image.width)) × \(String(image.height)) · \(model.displayName(for: image.settings.modelID)) · Seed \(String(image.seed))"
       }

       private func buttons(labelled: Bool) -> some View {
           HStack(spacing: 8) {
               Button {
                   model.reuseSettings(of: image)
               } label: {
                   if labelled { Text("Reuse Settings") } else { Image(systemName: "arrow.uturn.backward") }
               }
               .buttonStyle(.bordered)
               .help("Reuse Settings (⌘R)")
               .accessibilityLabel("Reuse Settings")
               Button {
                   act { await model.exportSelected() }
               } label: {
                   if labelled {
                       Label("Export…", systemImage: "square.and.arrow.up")
                   } else {
                       Image(systemName: "square.and.arrow.up")
                   }
               }
               .buttonStyle(.bordered)
               .help("Export…")
               .accessibilityLabel("Export")
               Button {
                   act { await model.revealSelected() }
               } label: {
                   Image(systemName: "folder")
               }
               .buttonStyle(.borderless)
               .help("Show in Finder")
               .accessibilityLabel("Show in Finder")
               Button(role: .destructive) {
                   act { await model.deleteSelected() }
               } label: {
                   Image(systemName: "trash")
               }
               .buttonStyle(.borderless)
               .help("Move to Trash")
               .accessibilityLabel("Move to Trash")
           }
           .fixedSize()
       }

       /// Makes this image the only gallery selection, then runs a D37 action on it.
       private func act(_ action: @escaping @MainActor () async -> Void) {
           guard model.galleryBulk == nil else { return }
           model.selectGalleryImage(image.id, click: .plain)
           Task { await action() }
       }
   }
   ```

2. In `ContentCanvas.body`, change the `if let image = model.canvasImage { … }` branch to:

   ```swift
   if let image = model.canvasImage {
       SelectedImageView(model: model, image: image)
           .id(image.id)
       CanvasImageBar(model: model, image: image)
   }
   ```

   Leave the `VStack(spacing: 12)` and the `StepProgressView` below it unchanged.
3. Add `import MCLibrary` to the file if it is not already there (it is: `LibraryImage`).
4. Format the file.

## Do not touch

- `SelectedImageView`'s accessibility element "Selected image: <prompt>" (the smoke suite waits for it).
- `ImageCell` and its menus (the smoke suite uses "Reuse prompt" and "Reuse all settings").
- D37 semantics: no confirmation for Move to Trash, and export always keeps the metadata.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0 (`python3 scripts/gui-smoke/run_smoke.py --models "$HOME/Library/Application Support/mlx-create/Models/Weights" --model-id Runpod/FLUX.2-klein-4B-mflux-4bit`).
6. Add this check to `UITests/MLXCreateUITests/GenerateFlow.swift`, at the end of the step "The image reaches the canvas and the gallery":

   ```swift
   require(app.buttons["Reuse Settings"], "the canvas has no Reuse Settings button for the new image")
   require(app.buttons["Export"], "the canvas has no Export button for the new image")
   ```

   The smoke run must pass with it.

With the capture kit, one model, one generated image selected, window at 1100×692:

7. In `ax dump`, `AXButton` "Reuse Settings", "Export", "Show in Finder" and "Move to Trash" are all inside the canvas group, and their frames are inside the window frame (visible without scrolling at 1100×640).
8. The facts line contains `× ` and no "." or "," between digits: run `ax dump | grep "Seed "` and check the value matches the regex `^[0-9]+ × [0-9]+ · .+ · Seed [0-9]+$`.
9. Press Export (`ax press <pid> "=Export"`): an `AXSheet` or a save panel window appears whose name field holds the image's base name. Press Escape to cancel.
10. Captures `S06_small_light.png` and `S06_large_dark.png` are attached to the PR.

## Resolution

Done on branch `feat/audit-s06-canvas-image-bar`, commits `84be0d9` (bar) and `6e0c69a` (status stack moved off the bar). The bar binds to `canvasImage` (I02), not the selected gallery image, and its four buttons are disabled while a bulk gallery action runs. A GUI pass found the step bar overlapping the bar's prompt by 32 pt; `6e0c69a` anchors the status stack to the image's bottom edge. Code review then found that Export, Show in Finder and Move to Trash ended the canvas following the running batch (they route through `selectGalleryImage`), so the bar now restores the follow set after selecting its image. Exercised: `swift test`, lint, the Debug `xcodebuild`, GUI smoke (`TEST SUCCEEDED`, one added canvas assertion in `GenerateFlow.swift`), and acceptance 7 and 8 plus captures (`screens/S06_small_light.png`, `screens/S06_large_dark.png`). Not exercised: the Export panel (acceptance 9) was not separately recorded, and no test drives the bar's three gallery actions (the bar's `act` is a private view method).

Cross-model review also found that the bar's Export, Show in Finder and Move to Trash ran in a task that read the gallery selection when it started, so a selection change in between could redirect them. They now name the image (`exportSelected(only:)` and its siblings), and `anActionNamedForOneImageIgnoresTheSelection` covers Show in Finder.
