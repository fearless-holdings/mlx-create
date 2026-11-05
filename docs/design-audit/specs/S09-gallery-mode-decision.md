# S09 · Gallery: decide D33's open question, and give the grid room to browse (needs an HLD decision first)

| | |
|---|---|
| Tag | STRUCTURE |
| Severity (Nielsen 0–4) | 2, minor: finding an old image means scrolling a two-column, 260 pt strip; on a 1680 pt window the extra width all goes to the canvas |
| Frequency | Every "find an old image" task; grows with the library |
| Heuristics | H7 Flexibility and efficiency of use; H6 Recognition rather than recall |
| User task | (c) find and reuse an old image |
| Strategy metric | Week-4 active generators (libraries grow); nothing to learn |
| HLD decisions | **Resolves the open question in D33 and HLD §10** ("Gallery mode (open question) … whether it still ships in a later phase, or the right panel grows to host search, is undecided"). **Record the decision in the HLD before any code** |
| Size | L |
| Depends on | S05 (menu commands), I08 (arrow keys in the grid) |

## Evidence

- Screenshots: `screens/06-populated-gallery_small_light.png` (two columns of 114 pt at 1100 pt), `screens/06-populated-gallery_large_light.png` (still two columns at 1680 pt; the canvas takes everything else), `screens/08-enhancer-memory-refusal_small_light.png` (one column after relaunch, V04).
- Code: `Sources/MCApp/MainWindow.swift`, `GalleryView(model:).frame(minWidth: 200, idealWidth: 260)` with the canvas at `.layoutPriority(1)`. `GalleryLayout` (`GalleryCollectionView.swift`) fits 100–120 pt columns.
- HLD §10 already sketches a full-window grid with search, "double-click opens an image in the canvas", with ⌘1/⌘2 for Canvas/Gallery.
- Comparison: Photos switches between a full-window grid and a single photo, with arrow keys moving between photos. Image Playground shows its gallery in a toggleable sidebar. Draw Things keeps a permanent narrow version-history column, the pattern mlx-create copies today.

## Decision to record first

Two options; the audit recommends **A**.

- **A. Gallery view mode (recommended).** View ▸ Canvas (⌘1) and View ▸ Gallery (⌘2). In Gallery mode the window shows only the gallery (search, filters and grid) at full width; the composer and canvas are hidden, not destroyed. Return, or "Open in Canvas" in the tile menu, opens the image in Canvas mode. The mode persists across launches. Three panels stay the default (D33 unchanged otherwise).
- **B. Wider right panel only.** Raise the gallery's ideal width to 372 pt (three columns) and do nothing else. Simpler, but it takes 112 pt from the canvas at every window size and does not fix browsing large libraries.

Add to `docs/HLD.md` (next free ID; D52 if S08's D51 is taken):

> **D52** | **Gallery mode ships as a view mode of the main window.** View ▸ Canvas (⌘1) shows the three panels (D33); View ▸ Gallery (⌘2) shows the gallery alone at full width, with the same search, filters and actions. Return or "Open in Canvas" returns to Canvas with that image selected. The mode is stored in `UserDefaults` (`mainWindowMode`). No separate window | Browsing a growing library in a 260 pt strip is slow; a mode keeps the three-panel layout as the default while giving the grid the window when the user asks (design audit S09) |

Update §10 "Gallery mode (open question)" to point at the decision.

## Target behavior (option A)

- `AppModel.showsGalleryOnly: Bool` is persisted under `mainWindowMode` as the strings `"canvas"` / `"gallery"`, defaulting to canvas.
- `MainWindow.body`: when `showsGalleryOnly`, the `HSplitView` is replaced by `GalleryView(model: model)` at full width. The engine banner and the toolbar stay. The minimum window size stays at 1100×640.
- In Gallery mode, `GalleryLayout` uses 160–200 pt tiles (`minSide 160`, `maxSide 200`) for a full-window grid; in the right panel it keeps 100–120 pt.
- View menu: "Canvas" ⌘1 and "Gallery" ⌘2 (`CommandGroup(before: .toolbar)` in `MainCommands`, see S05), each with a check mark for the current mode (`Toggle` or `Picker` with `.inline`).
- Return on a focused grid (I08 handles arrows) and the new tile menu item **Open in Canvas** (first item, above "Reuse prompt") set `showsGalleryOnly = false` and select the image.

## Edit steps (only after the decision is merged)

1. `AppModel.swift`: add `static let windowModeDefaultsKey = "mainWindowMode"` and `public var showsGalleryOnly = false { didSet { defaults.set(showsGalleryOnly ? "gallery" : "canvas", forKey: Self.windowModeDefaultsKey) } }`. In `init`, set `self.showsGalleryOnly = defaults.string(forKey: Self.windowModeDefaultsKey) == "gallery"`.
2. `AppModel+GalleryActions.swift`: add

   ```swift
   /// Shows an image in the canvas and leaves Gallery mode (D52).
   func openInCanvas(_ id: UUID) {
       selectGalleryImage(id, click: .plain)
       showsGalleryOnly = false
   }
   ```

3. `MainWindow.swift`: wrap the `HSplitView { … }` in `if model.showsGalleryOnly { GalleryView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity) } else { HSplitView { … } }`.
4. `GalleryCollectionView.swift`:
   - Give `GalleryLayout` an init parameter or settable properties `minSide`/`maxSide`, turning the `static let`s into instance `var`s that default to 100/120.
   - In `GalleryCollection`, pass `model.showsGalleryOnly ? (160, 200) : (100, 120)` in `makeNSView`, and update it in `updateNSView` when it changes. Changing the properties must call `invalidateLayout()`.
   - In `GalleryCollectionView.keyDown`, handle Return (keyCode 36) with no modifiers by calling a new `onOpen` closure. `Coordinator` sets `collectionView.onOpen = { [model] in if let id = model.selection { model.openInCanvas(id) } }`.
5. `GalleryView.swift`, `ImageCell.actions`: add `Button("Open in Canvas") { model.openInCanvas(image.id) }` as the first item, followed by a `Divider()`. Add the same as an accessibility action.
6. `MainCommands.swift` (S05): add

   ```swift
   CommandGroup(before: .toolbar) {
       Picker("Show", selection: Binding(
           get: { model?.showsGalleryOnly ?? false },
           set: { model?.showsGalleryOnly = $0 })
       ) {
           Text("Canvas").tag(false).keyboardShortcut("1", modifiers: .command)
           Text("Gallery").tag(true).keyboardShortcut("2", modifiers: .command)
       }
       .pickerStyle(.inline)
       .disabled(model == nil)
   }
   ```

   If `keyboardShortcut` on a Picker item does not attach, use two `Button`s ("Canvas", "Gallery") whose titles get a leading "✓ " for the current mode. Prefer the Picker.
7. Tests: add `Tests/MCAppTests/WindowModeTests.swift`. Check that `showsGalleryOnly` persists through `AppHarness.relaunch`, and that `openInCanvas` sets `selection` and clears `showsGalleryOnly`.
8. Format the touched files.

## Do not touch

- Search, filters, multi-select and D37 actions: Gallery mode reuses `GalleryView` as it is.
- The three-panel default (D33).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including `WindowModeTests` (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0.
6. `docs/HLD.md` has the new decision row, and §10 no longer calls Gallery mode an open question.

With the capture kit, 25+ images, window 1680×1050:

7. ⌘2: `ax dump` shows no `AXTextArea` "Prompt" and no `AXSplitter`. The grid shows at least 7 columns: count distinct tile x positions in the first row.
8. Select a tile, press Return: `ax dump` shows the "Prompt" text area again, and the canvas `AXImage` desc contains that tile's prompt.
9. Captures `S09_gallery_large_light.png` and `S09_gallery_large_dark.png` are attached to the PR.

## Resolution

Option A, approved by the author on 2026-11-05 as D52 (§10's open question now points at it). Done in [#41](https://github.com/fearless-holdings/mlx-create/pull/41), stacked on [#40](https://github.com/fearless-holdings/mlx-create/pull/40). View ▸ Canvas (⌘1) and View ▸ Gallery (⌘2) switch the mode, Return on a highlighted tile and the tile menu's **Open in Canvas** return to Canvas with that image selected, and the mode is stored as `mainWindowMode`. The code follows the spec's edit steps, with these differences:

- `GalleryCollection` takes a `fullWindow` parameter from `GalleryView` (which reads `model.showsGalleryOnly`), so SwiftUI re-runs `updateNSView` on a mode change; the tile limits (`minSide`/`maxSide`, now instance properties of `GalleryLayout`) are set there.
- Return (36) and keypad Enter (76) both open the image. Open in Canvas is also an accessibility action on the tile.
- `SeedChoice` and `RunningProgress` moved out of `AppModel.swift` into files of their own, in a separate commit before the feature: the file was over its size budget.

Exercised: `swift test` (293 tests; `WindowModeTests` checks the mode survives a relaunch and that `openInCanvas` selects the image, leaves Gallery mode and stores `canvas`), strict format lint, the Debug `xcodebuild`, and the real app in a scratch home with 30 images and FLUX.2 klein 4B linked in, at 1680×1050, driven through accessibility and System Events: View ▸ Gallery and ⌘2 give a grid with no `AXTextArea` "Prompt" and no `AXSplitter` and 9 tile columns (check 7); a tile pressed then Return brings the Prompt text area back with `AXImage "Selected image: scratch image 25"` on the canvas (check 8); launching with the stored `gallery` mode opens in Gallery mode. Not exercised: the GUI smoke (its test runner needs a system authentication prompt that nobody answered at the Mac), and the Open in Canvas menu item with the mouse. The dark and light captures (check 9) are attached in a PR comment; the dark capture's pixels were not inspected by hand, only the accessibility tree behind it.
