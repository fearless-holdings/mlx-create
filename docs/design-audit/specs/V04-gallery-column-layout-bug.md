# V04 · Gallery: two columns after launch, not one

| | |
|---|---|
| Tag | VISUAL |
| Severity (Nielsen 0–4) | 2, minor: after a relaunch the 260 pt gallery shows a single 114 pt column in the middle, half the images it fits, until something reloads it |
| Frequency | Every launch with a populated gallery (observed twice: at 1100 pt and at 1680 pt windows) |
| Heuristics | H4 Consistency and standards; H8 Aesthetic and minimalist design |
| User task | (c) find and reuse an old image |
| Strategy metric | Week-4 active generators (returning users see this first) |
| HLD decisions | No D* change |
| Size | S |
| Depends on | none |

## Evidence

- Screenshots: `screens/08-enhancer-memory-refusal_small_light.png` and `screens/07-engine-error-banner_small_light.png` (after relaunch, one centred column in the 260 pt panel); `screens/11-lora-civitai_large_light.png` (one column at 1680 pt); compare `screens/06-populated-gallery_small_light.png` (two columns at the same width, before relaunch).
- `ax dump` after relaunch: tiles at x = 3143 (one column, `GalleryLayout` margin 65 pt); before: x = 3090 and 3212 (two columns).
- Code: `Sources/MCApp/GalleryCollectionView.swift`, `GalleryLayout.prepare()` fits columns to `collectionView.bounds.width`, and `shouldInvalidateLayout(forBoundsChange:)` re-fits only when the **bounds** width changes. Likely cause, inferred from the code and not traced in a debugger: at first layout the collection view's width is narrower than the final clip width (the hosting `NSScrollView` is sized after the document view), so the layout fits one column. `GalleryCollectionView.layout()` then widens the frame to the clip width with `setFrameSize`, a frame change that does not invalidate the flow layout.
- Columns: `available = width − 2 × 12`, `columns = (available + 8) / (100 + 8)`. Width 236 gives 2 columns; a width under 224 gives 1.

## Target behavior

The grid always fits columns to the current clip width: two columns at the default 260 pt panel, right after launch and after every resize.

## Edit steps

1. `Sources/MCApp/GalleryCollectionView.swift`, `GalleryCollectionView.layout()`: when the frame size changes, invalidate the layout so `prepare()` re-fits:

   ```swift
   override func layout() {
       if let clip = enclosingScrollView?.contentView {
           let content = collectionViewLayout?.collectionViewContentSize ?? .zero
           let size = NSSize(width: clip.bounds.width, height: max(content.height, clip.bounds.height))
           if frame.size != size {
               let widthChanged = frame.size.width != size.width
               setFrameSize(size)
               // The flow layout fitted its columns to the old width; re-fit now (V04).
               if widthChanged { collectionViewLayout?.invalidateLayout() }
           }
       }
       super.layout()
   }
   ```

2. `GalleryLayout.prepare()`: fit to the clip width when there is one, because the document view can lag behind:

   ```swift
   override func prepare() {
       if let collectionView {
           let width = collectionView.enclosingScrollView?.contentView.bounds.width ?? collectionView.bounds.width
           fit(width: width)
           laidOutWidth = width
       }
       super.prepare()
   }
   ```

   Also make `shouldInvalidateLayout(forBoundsChange:)` compare against the same clip width.
3. Format the file.

## Do not touch

- `fit(width:)`'s maths (100–120 pt tiles, 8 pt spacing, 12 pt inset) and `applyKeepingScroll`.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0.

With the capture kit and a home with at least 6 images:

6. Quit and relaunch, with the window at 1100×692 before quitting. Immediately after the window appears, `ax dump | grep 'desc="Image: '` shows tiles at exactly **2** distinct x positions. Repeat three launches; all show 2.
7. Resize to 1680×1050 and back to 1100×692 (`cap.py big`, `cap.py small`). There are still 2 distinct x positions.
8. Attach `V04_after_relaunch_small_light.png`.
