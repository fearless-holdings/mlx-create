# I08 · Gallery: arrow keys move between images, and tiles are told apart by VoiceOver

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 2, minor: browsing a batch means clicking every thumbnail; VoiceOver reads six tiles of a batch identically |
| Frequency | Every review of a batch; every VoiceOver session |
| Heuristics | H7 Flexibility and efficiency of use; H4 Consistency and standards (Photos and Finder move with the arrow keys) |
| User task | (c) find and reuse an old image; (b) compare the images of a batch |
| Strategy metric | Time to first kept image (choosing the keeper of a batch) |
| HLD decisions | No D* change. D37's click rules (plain, ⌘ and ⇧) stay |
| Size | S |
| Depends on | none (I02 makes the canvas follow new images; arrows hand control back to the user like a click) |

## Evidence

- Measured with the capture kit. After clicking a tile, the grid has keyboard focus (`ax focused` → `AXList/AXCollectionList`). Right, Down and Left arrows leave the selection ring and the canvas on the same image: crops taken before and after each key were identical. `screens/06-populated-gallery_small_light.png` shows the grid. Delete works (it is handled in `GalleryCollectionView.keyDown`).
- The audit's `ax dump` of the populated gallery: all six tiles of a batch carry the same label, "Image: a red vintage bicycle leaning against a pastel wall in Lisbon, afternoon sun".
- Code: `Sources/MCApp/GalleryCollectionView.swift`. `GalleryCollectionView.keyDown` handles only keyCodes 51 and 117. `collectionView.isSelectable = false`, so AppKit's own arrow handling is off. `Sources/MCApp/GalleryView.swift`, `ImageCell.body`: `.accessibilityLabel("Image: \(image.prompt)")`.
- Comparison: Photos, "Go to the next photo or video: Press the arrow keys" (Photos User Guide, *View photos and videos*).

## Target behavior

- With the grid focused: ← and → select the previous and next image; ↑ and ↓ move by one row (the current column count). Each move behaves like a plain click: the canvas shows the image, and the gallery selection becomes that image alone. The grid scrolls so the image is visible. With nothing selected, any arrow selects the first image. Moves stop at the ends and do not wrap.
- Tile accessibility label: `"Image: \(prompt), \(width) × \(height), seed \(seed)"`, with plain integers (no grouping separators).

## Edit steps

1. `Sources/MCApp/GalleryCollectionView.swift`:
   - In `GalleryLayout`, add `private(set) var columns = 1`, and in `fit(width:)`, after computing `columns`, assign `if self.columns != columns { self.columns = columns }`. Rename the local constant if the compiler complains about shadowing (e.g. `let fitted = …`).
   - In `GalleryCollectionView`, add `var onMove: ((Int) -> Void)?`. In `keyDown(with:)`, before `super.keyDown(with: event)`, handle the plain arrow keys:

     ```swift
     let columns = (collectionViewLayout as? GalleryLayout)?.columns ?? 1
     if plain {
         switch event.keyCode {
         case 123: onMove?(-1); return       // ←
         case 124: onMove?(1); return        // →
         case 125: onMove?(columns); return  // ↓
         case 126: onMove?(-columns); return // ↑
         default: break
         }
     }
     ```

     Restructure the existing `if plain, event.keyCode == 51 || … { onDelete?() } else { super.keyDown(with: event) }` so that Delete, the arrows and `super` are each reached exactly once.
   - In `Coordinator.makeScrollView()`, next to `collectionView.onDelete = …`, add `collectionView.onMove = { [weak self] offset in self?.moveSelection(by: offset) }`, and add to `Coordinator`:

     ```swift
     /// Arrow keys: a plain click on the neighbouring image, scrolled into view (I08).
     private func moveSelection(by offset: Int) {
         let ids = model.galleryImages.map(\.id)
         guard !ids.isEmpty else { return }
         let target: Int
         if let current = model.selection.flatMap({ ids.firstIndex(of: $0) }) {
             target = min(max(current + offset, 0), ids.count - 1)
             guard target != current else { return }
         } else {
             target = 0
         }
         model.selectGalleryImage(ids[target], click: .plain)
         if let indexPath = dataSource?.indexPath(for: ids[target]) {
             collectionView?.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
         }
     }
     ```

2. `Sources/MCApp/GalleryView.swift`, `ImageCell.body`: change the label to `.accessibilityLabel("Image: \(image.prompt), \(String(image.width)) × \(String(image.height)), seed \(String(image.seed))")`.
3. Format the touched files.

## Do not touch

- ⌘-click and ⇧-click rules (D37, `selectGalleryImage`), Delete and ⌘A.
- Paging (`willDisplay`). Arrowing into unloaded pages is handled by it.
- The label prefix "Image: ". The smoke suite matches tiles by that prefix plus the prompt token.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0.

With the capture kit, at least 6 images from one batch, window at 1100×692 (two columns):

6. Click the first tile (`ax press <pid> "Image: " 0`), then press → (`key code 124`). The canvas `AXImage` desc changes, and the selected tile is the second one. Check with a capture (`cap.py shot`; the blue ring moves one tile right). Press ↓ (`key code 125`): the ring moves down one row.
7. `ax dump | grep 'desc="Image: '` shows labels that end in `seed <digits>` and are pairwise different within the batch.
