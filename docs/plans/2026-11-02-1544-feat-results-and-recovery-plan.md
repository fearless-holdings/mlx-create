---
title: "feat: results and recovery (audit I02, I03, then S06)"
type: feat
date: 2026-11-02
execution: code
---

# Results and recovery: I02, I03, then S06

## Summary

Ship the design audit's "results and recovery" cluster (`docs/design-audit/README.md` section 4, item 4) next, ahead of the window-structure block that section 3 lists first. The first-run path is merged (#26), so the next gap in *time to first kept image* and *failed generation rate* is the moment after Generate.

I02 (canvas follows generation) and I03 (out-of-memory recovery) go in one branch, because I03 needs I02's `canvasFollowedJobs`. S06 (canvas image bar) follows as its own PR: it edits the same `ContentCanvas.body`, and keeping it separate keeps the canvas diffs reviewable. Each spec in `docs/design-audit/specs/` carries exact edit steps and acceptance checks; the units below point at them and add what the implementer must honor.

## Decisions

- **Order: results and recovery before window structure.** README section 1 ranks I03 third, I02 fourth and S06 sixth. S03, S04 and S05 are not in the top 10. S02 (fifth) waits behind S03 in section 3 only so its control-count target lands. I02 has no dependencies and gates I03, I05 and S06. The user may redirect to README section 3's literal order (S05, S04, S03, S02); the two orders barely conflict.
- **No HLD change.** Neither I02 nor I03 changes a `D*` entry (both specs say so). S06 uses the existing D37 actions.
- **Spec line numbers describe `633e737`.** The I02 anchors were re-checked on `main` at `5a0582b` and all still exist: `selection = job.id` in `AppModel.swift`, `if selection == jobID` in `AppModel+Projection.swift`, the "Select an image…" text in `CanvasView.swift`, `model.selection = job.id` in `QueueStripView.swift`, and `selectGalleryImage` in `AppModel+GalleryActions.swift`. Re-check I03's and S06's anchors when each unit starts.

## Implementation units

### U1. Docs tracker fix

- **Files:** `docs/design-audit/README.md`.
- README sections 2 and 3 still say "PR pending" for S01, I01, I10 and I12, though #26 merged. Mark them `done (PR #26)` and bump the Progress count and date.
- **Verify:** read the table.

### U2. I02: canvas follows generation (M)

Spec: `docs/design-audit/specs/I02-canvas-follows-generation.md`.

- **Files:** `Sources/MCApp/AppModel.swift`, `AppModel+Projection.swift`, `AppModel+Selection.swift`, `AppModel+GalleryActions.swift`, `AppModel+Collections.swift`, `CanvasView.swift`, `QueueStripView.swift`; tests in `Tests/MCAppTests/AppModelTests.swift`.
- Add `canvasFollowedJobs`, `canvasFallbackImageID`, `canvasImage`, `isStartingJob` and `selectJob(_:)`. Show "Starting…" instead of "Select an image…" while a job starts. Keep the last image under the step bar. Every image of a followed job takes the canvas until the user clicks a tile or cell.
- **Tests:**
  - `theCanvasKeepsThePreviousImageWhileTheNextJobRuns`
  - `everyImageOfABatchTakesTheCanvas`
  - `aGalleryClickStopsFollowing`
  - The existing `AppModelTests`, `CollectionsTests` and `LoRAStackTests` pass unchanged.
- **Do not touch:** `gallerySelection`, the D37 actions, `GalleryCollection`, `ImageCell`, the executor, queue order.

### U3. I03: out-of-memory recovery (M)

Spec: `docs/design-audit/specs/I03-out-of-memory-recovery.md`. Depends on U2.

- **Files:** `Sources/MCEngine/EngineError.swift`, `Sources/MCApp/AppModel+Selection.swift`, `AppModel+Projection.swift` (`reloadQueue()`), `AppModel+Queue.swift` (`retry`), `CanvasView.swift` (`FailureCard`); tests in `Tests/MCEngineTests/EngineErrorMappingTests.swift` and `AppModelTests`.
- Rewrite the out-of-memory copy, since the app has already freed its own memory. Map a chat 400 whose message contains "GPU memory" to `.enhancerOutOfMemory`. Show a canvas failure card with **Try Again** and **Dismiss**. A retried job is followed again.
- **Tests:**
  - A chat admission refusal maps to `.enhancerOutOfMemory`.
  - The same body on the image route is still `.badRequest`.
  - A followed job that fails takes the canvas.
  - Retry re-follows the job.

### U4. S06: canvas image bar (M, separate PR)

Spec: `docs/design-audit/specs/S06-canvas-image-bar.md`. No dependencies, but do it after U2 and keep I02's rule: `CanvasImageBar` sits directly after `SelectedImageView`, outside the step-bar `.overlay`.

- Shows the prompt, facts, and the Export and Reuse actions under the canvas image. Export stays a byte copy with metadata (D37).

## Verification

- `swift test`, `swift format lint --strict` over all tracked Swift files, and the `xcodegen` + `xcodebuild` build.
- GUI smoke before each UI PR (`scripts/gui-smoke/run_smoke.py`, `AGENTS.md`).
- I02 acceptance 6 and 7: with the capture kit `ax dump` polling, "Select an image in the gallery, or generate one." never appears during a x3 batch, and the canvas ends on the newest gallery image.
- I03's out-of-memory acceptance needs a real memory failure, so expect it to be partly deferred, as I06 was. Record that in the spec's Resolution section.
- On shipping each finding: update its README Status row, add its spec Resolution section, and put `Audit: <ID>` in the commit trailer and PR body.
