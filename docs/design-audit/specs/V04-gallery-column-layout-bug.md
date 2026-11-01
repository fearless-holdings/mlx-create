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
- Cause (traced 2026-11-01 with temporary logging, then removed): the bug needs a gallery taller than its panel, so the vertical scroller appears and narrows the clip 260 → 243 pt (with six images and no scroller it does not occur). The first layout pass fits the grid at 260 pt (`item = 114`, two columns). The second pass runs at 243 pt, where 114 pt tiles fit one column only. Its fit ran **inside `GalleryLayout.prepare()`**, and a fit made while the flow layout is preparing left the attributes computed from the previous item size: the log showed `itemSize = 105.5` yet every cell frame stayed 114 pt in one column. The theory above (a frame change that never invalidates the layout) was not the cause: a first attempt that read the clip width once in `prepare()` and invalidated on a frame-width change still left one column on three of three launches.
- Fix: `GalleryCollectionView.layout()` calls `GalleryLayout.fit(width:)` with the clip width before `super.layout()`, and `GalleryLayout.prepare()` and `shouldInvalidateLayout(forBoundsChange:)` are gone. Measured live: two distinct cell x positions (3090 and 3204, 105 pt cells) on three of three relaunches; 1680×1050 and back to 1100×692 both two; dragging the gallery splitter to 378 pt gives three columns, and to the 200 pt minimum one.
- Earlier code reading (superseded): `GalleryLayout.prepare()` fit columns to `collectionView.bounds.width`, and `shouldInvalidateLayout(forBoundsChange:)` re-fit only when the **bounds** width changed.
- Columns: `available = width − 2 × 12`, `columns = (available + 8) / (100 + 8)`. Width 236 gives 2 columns; a width under 224 gives 1.

## Target behavior

The grid always fits columns to the current clip width: two columns at the default 260 pt panel, right after launch and after every resize.

## Edit steps

1. `Sources/MCApp/GalleryCollectionView.swift`, `GalleryCollectionView.layout()`: fit the grid to the clip width before the layout pass starts, so the flow layout reads its item and inset sizes at the start of the pass:

   ```swift
   override func layout() {
       if let clip = enclosingScrollView?.contentView, let grid = collectionViewLayout as? GalleryLayout {
           grid.fit(width: clip.bounds.width)
           let content = grid.collectionViewContentSize
           let size = NSSize(width: clip.bounds.width, height: max(content.height, clip.bounds.height))
           if frame.size != size { setFrameSize(size) }
       }
       super.layout()
   }
   ```

2. `GalleryLayout`: delete `prepare()`, `laidOutWidth` and the `shouldInvalidateLayout(forBoundsChange:)` override, and make `fit(width:)` internal (not private) with a `guard width > 0` (a zero item size makes AppKit raise).
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
