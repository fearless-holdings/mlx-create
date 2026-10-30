---
title: Gallery Column Fit After Launch - Plan
type: fix
date: 2026-10-30
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Gallery Column Fit After Launch - Plan

## Goal Capsule

- **Objective:** After every launch with a populated library, the gallery shows as many tiles per row as its width fits (two at the default 260 pt panel), without the user resizing or reloading anything.
- **Means:** Fit the grid to the clip width in `GalleryCollectionView.layout()`, before the layout pass starts, not inside `GalleryLayout.prepare()` (KTD1, as built; the first attempt in KTD1 did not work).
- **Authority:** `docs/design-audit/specs/V04-gallery-column-layout-bug.md` carries the proposed edit and acceptance checks. This plan sequences and bounds that spec. `docs/HLD.md` D33 and D37 stay untouched.
- **Execution profile:** One small fix in one file, then a live relaunch check on the real app. The root cause is inferred, so the relaunch check, not the edit, decides done.
- **Stop conditions:** Stop and report if the spec's edit still leaves one column after relaunch and a second attempt does not explain why. Do not widen into the other audit specs.
- **Who finishes:** The implementer ships it, including the live check. Developer Mode and a quit mlx-create are prerequisites for the GUI smoke.

## Product Contract

### Summary

Make the gallery grid fit its columns to the width the user actually sees, right after launch and after every resize. The fix lives in the gallery's collection view and layout, and changes no tile sizing rules.

### Problem Frame

On a relaunch with a populated gallery, the 260 pt right panel shows a single 114 pt column centred in the middle, about half the images it could fit, until something reloads it. It was observed twice, at 1100 pt and at 1680 pt windows. The audit measured tiles at one x position after launch and at two before.

The grid fits columns from its collection view's width. The likely cause, read from code and never traced in a debugger, is that the hosting scroll view sizes its clip after the collection view has already laid out, so the first fit sees a narrower width. The later frame correction is a frame change that never asks the layout to fit again.

### Requirements

- R1. Right after launch with a gallery taller than its panel (twelve images; with six the scroller never appears and the bug does not occur), the gallery at the default panel width shows two columns. Three consecutive relaunches agree.
- R2. After the window is resized to a large size and back to the small one, the gallery shows two columns again.
- R3. The tile sizing rules do not change: 100–120 pt tiles, 8 pt spacing, 12 pt inset, and the scroll-position keeping on updates.
- R4. The app's smoke contract holds: tile labels beginning "Image: ", the tile menu items "Reuse prompt" and "Reuse all settings", and the gallery's Delete and ⌘A keys.

### Scope Boundaries

- Gallery arrow keys and distinct tile labels (I08) are not part of this plan.
- The gallery's width and mode decision (S09) is not part of this plan.
- Changing panel minimum widths is not part of this plan. At the 200 pt panel minimum a single column is correct.

## Planning Contract

### Key Technical Decisions

- KTD1. **Fit to the clip width before the layout pass, in `layout()`.** The first attempt, as the spec first proposed it (fit to the clip width inside `prepare()` plus `invalidateLayout()` on a frame-width change), left one column on three of three relaunches. Temporary logging showed why: with a vertical scroller the clip narrows 260 → 243 pt, the fit inside `prepare()` set `itemSize = 105.5`, and the flow layout still produced 114 pt cells in one column. The built fix moves the fit into `GalleryCollectionView.layout()` before `super.layout()` and deletes `prepare()`, `laidOutWidth` and the `shouldInvalidateLayout(forBoundsChange:)` override (R1, R2).
- KTD2. **The relaunch check is the acceptance bar; the headless repro is a bonus.** The failure is an AppKit sizing-order effect that a unit test may not reproduce. A headless repro that sizes a hosting scroll view after first layout is worth trying first because it also confirms or refutes the inferred cause. If it cannot be made to fail before the fix, drop it and rely on the live check rather than keep a test that passes either way.

### Assumptions

- The audit's code description matched `main` when re-read at `efc3734`; its inferred cause did not (see KTD1).
- `GalleryView` hosts the grid at an ideal width of 260 pt with a 200 pt minimum, so the default panel yields two columns by the layout's own arithmetic.

## Implementation Units

### U1. Re-fit the grid to the clip width

- **Goal:** The grid's column count always follows the visible clip width (R1, R2, R3).
- **Dependencies:** none
- **Files:**
  - `Sources/MCApp/GalleryCollectionView.swift` (modify)
  - `Tests/MCAppTests/` (new test file only if the headless repro in KTD2 works; none exists for the gallery today)
- **Approach:**
  1. In `GalleryCollectionView.layout()`, call `GalleryLayout.fit(width:)` with the clip width before `super.layout()`, then size the frame from the content height as before.
  2. Delete `GalleryLayout.prepare()`, `laidOutWidth` and the `shouldInvalidateLayout(forBoundsChange:)` override. Make `fit(width:)` internal and return early for a width of zero (a zero item size makes AppKit raise).
  3. Leave the fit maths and `applyKeepingScroll` alone (R3).
- **Execution note:** Try a headless AppKit repro first: a scroll view whose document view is laid out before the clip reaches its final width. If it fails on `main` and passes after, keep it as a regression test. If it passes on `main`, the inferred cause is wrong or not reproducible this way; do not keep it, and let U2's live check judge the fix.
- **Patterns to follow:** The existing write-only-on-change discipline in `GalleryLayout.fit(width:)`, which exists to avoid an endless invalidate loop. The new invalidation must not loop either.
- **Test scenarios:**
  - Scroll view clip at 260 pt, document view first laid out narrower: after layout settles, tiles sit at two distinct x positions.
  - Clip widened from 260 to 700 pt and back to 260 pt: the column count follows each width and ends at two.
  - Clip at 200 pt (panel minimum): one column, tiles centred.
- **Verification:** `swift build` and `swift test` pass. The scenarios above pass if they were kept; otherwise U2 carries the proof.

### U2. Prove it on the real app

- **Goal:** The relaunch and resize behavior is correct in the running app, and the smoke contract still holds (R1, R2, R4).
- **Dependencies:** U1
- **Files:** none modified. Evidence screenshot attached to the PR: `V04_after_relaunch_small_light.png`.
- **Approach:**
  1. Export the real `com.fearless.mlx-create` defaults first (`capture-kit.md` §2). Every launch writes the real domain, so import them back after the last quit.
  2. Build a throwaway home from the kit's "one model installed" recipe (symlinked FLUX.2 klein 4B) and generate at least six images in it, for example with batch count 6. Never copy images from the real library.
  3. **Baseline first, on the unfixed build:** quit and relaunch three times, and right after the window appears dump the accessibility tree and count the distinct x positions of the "Image: " tiles. Expect one. If the baseline already shows two, the V04 cause is not reproduced; stop and report that instead of calling anything fixed.
  4. After U1, rebuild and repeat the same three relaunches on the same home. The relaunch window size is the app default, so there is no size to set before quitting.
  5. Resize to 1680×1050 and back to 1100×692 with the capture kit, then count again.
  6. Run the GUI smoke (`scripts/gui-smoke/run_smoke.py`) with mlx-create quit.
  7. Import the saved defaults back. Clean up by home path in argv, never by process name, and check for leftover `mlx-serve` and `mlx-create`.
- **Execution note:** If any post-fix relaunch still shows one column, stop there. Trace the first-layout widths (clip width, collection view width, frame width) before editing again, and update the V04 spec's Evidence with the real cause. Two things to watch while tracing: `shouldInvalidateLayout(forBoundsChange:)` receives the collection view's bounds, not the clip's, so U1's width comparison must read the clip from the collection view; and `layout()` sets the frame height from `collectionViewContentSize` before the new invalidation, so a large library may briefly show extra scroll range. Neither is a known defect; they are the first places to look.
- **Test scenarios:** Test expectation: none -- this unit is the live acceptance run for U1; its pass criteria are the counts in Approach steps 3–5 and the smoke result.
- **Verification:** Exactly two x positions on all three relaunches and after the resize round trip; GUI smoke exits 0 (exit 2 is NOT RUN, not a pass); screenshot attached.

## Verification Contract

| Gate | Command or check | Applies to |
|---|---|---|
| Build | `swift build` exits 0 | U1 |
| Tests | `swift test` exits 0 (about 40 s; past 2 minutes it is hung, bisect with `--filter`) | U1 |
| Lint | `swift format lint --strict --configuration .swift-format` over every tracked Swift file (`git ls-files '*.swift'`) prints nothing | U1 |
| App build | `xcodegen generate`, then `xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **` | U1 |
| Relaunch and resize | Two distinct tile x positions on three relaunches and after the resize round trip | U2 |
| GUI smoke | `python3 scripts/gui-smoke/run_smoke.py --models DIR --model-id ORG/NAME` exits 0 | U2 |

## Definition of Done

- U1 and U2 complete, every gate above passes, and the relaunch screenshot is attached.
- The tile sizing rules and scroll-keeping are unchanged in the diff.
- Any headless repro that did not fail before the fix is removed, not left in the tree.
- If the real cause differs from the spec's, the V04 spec's Evidence section says so.
- No stray `mlx-serve` or `mlx-create` process is left running.

## Sources

- `docs/design-audit/specs/V04-gallery-column-layout-bug.md` (the finding, edit and acceptance checks); `docs/design-audit/README.md` §12 (the root cause is inferred and its check tests the outcome).
- `Sources/MCApp/GalleryCollectionView.swift`: `GalleryCollectionView.layout()`, `GalleryLayout.fit(width:)`.
- `Sources/MCApp/GalleryView.swift` (panel frame 200 / 260 pt) and `Sources/MCApp/MainWindow.swift` (the `HSplitView`).
- `AGENTS.md` Commands and Verification sections for the gates and cleanup rules.
