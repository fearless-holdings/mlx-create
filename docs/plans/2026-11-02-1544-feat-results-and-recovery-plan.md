---
title: "feat: results and recovery (audit I02, I03, then S06)"
type: feat
date: 2026-11-02
execution: code
---

# Results and recovery: I02, I03, then S06

## Summary

Ship the design audit's "results and recovery" cluster (`docs/design-audit/README.md` section 3, item 4) next, ahead of the window-structure block that section 3 lists first. The first-run path is merged (#26), so the next gap in *time to first kept image* and *failed generation rate* is the moment after Generate.

I02 (canvas follows generation) and I03 (out-of-memory recovery) go in one branch, because I03 needs I02's `canvasFollowedJobs`. S06 (canvas image bar) follows as its own PR: it edits the same `ContentCanvas.body`, and keeping it separate keeps the canvas diffs reviewable. Each spec in `docs/design-audit/specs/` carries exact edit steps and acceptance checks; the units below point at them and add what the implementer must honor.

## Decisions

- **Order: results and recovery before window structure.** README section 1 ranks I03 third, I02 fourth and S06 sixth. S03, S04 and S05 are not in the top 10. S02 (fifth) waits behind S03 in section 3 only so its control-count target lands. I02 has no dependencies and gates I03 and I05; S06 depends on nothing but lands after I02 because both rewrite `ContentCanvas.body`. The user may redirect to README section 3's literal order (S05, S04, S03, S02). The cost of this order: after U4 the README section 4 task (a) walkthrough still has the seed and steps "to learn" and a left panel that scrolls at 1100×640. Only S02 removes those, so reaching that walkthrough's 0 "to learn" needs S02 in the next block.
- **No HLD change.** Neither I02 nor I03 changes a `D*` entry (both specs say so). S06 uses the existing D37 actions.
- **Spec line numbers describe `633e737`.** The I02 anchors were re-checked on `main` at `5a0582b` and all still exist: `selection = job.id` in `AppModel.swift`, `if selection == jobID` in `AppModel+Projection.swift`, the "Select an image…" text in `CanvasView.swift`, `model.selection = job.id` in `QueueStripView.swift`, and `selectGalleryImage` in `AppModel+GalleryActions.swift`. Re-check I03's and S06's anchors when each unit starts.

## Implementation units

### U1. Docs tracker fix

- **Files:** `docs/design-audit/README.md`, and the Resolution sections of `docs/design-audit/specs/S01-first-run-single-primary-action.md`, `I01-install-progress-visible.md`, `I10-license-sheet-single-action.md` and `I12-generate-disabled-reason.md`.
- README sections 2 and 3 still say "PR pending" for S01, I01, I10 and I12, though #26 merged. Replace each with `done (PR #26)`, and change "PR pending" in the four specs' Resolution sections to a link to #26. The Progress line (9 of 28 done, last updated 2026-11-02) already counts these four and stays as it is.
- **Verify:** read the table.

### U2. I02: canvas follows generation (M)

Spec: `docs/design-audit/specs/I02-canvas-follows-generation.md`.

- **Files:** `Sources/MCApp/AppModel.swift`, `AppModel+Projection.swift`, `AppModel+Selection.swift`, `AppModel+GalleryActions.swift`, `AppModel+Collections.swift`, `CanvasView.swift`, `QueueStripView.swift`; tests in `Tests/MCAppTests/AppModelTests.swift`.
- Add `canvasFollowedJobs`, `canvasFallbackImageID`, `canvasImage`, `isStartingJob` and `selectJob(_:)`. Show "Starting…" instead of "Select an image…" while a job starts, but not when the queue is paused or held by an engine failure, because the queue header says so there. Keep the last image under the step bar. Every image of a followed job takes the canvas until the user clicks a tile or cell. A plain, ⌘- or ⇧-click all hand control back until the next Generate, so `selectGalleryImage(_:click:)` clears the followed set in every case, not only `.plain`.
- **Tests:**
  - `theCanvasKeepsThePreviousImageWhileTheNextJobRuns`
  - `everyImageOfABatchTakesTheCanvas`
  - `aGalleryClickStopsFollowing`, including a ⌘-click case
  - Pausing with a queued job and nothing on the canvas shows neither "Starting…" nor "Select an image…" as if a job were starting.
  - The existing `AppModelTests`, `CollectionsTests` and `LoRAStackTests` pass unchanged.
- **Do not touch:** `gallerySelection`, the D37 actions, `GalleryCollection`, `ImageCell`, the executor, queue order.

### U3. I03: out-of-memory recovery (M)

Spec: `docs/design-audit/specs/I03-out-of-memory-recovery.md`. Depends on U2.

- **Files:** `Sources/MCEngine/EngineError.swift`, `Sources/MCApp/AppModel+Selection.swift`, `AppModel+Projection.swift` (`reloadQueue()`), `AppModel+Queue.swift` (`retry`), `CanvasView.swift` (`FailureCard`); tests in `Tests/MCEngineTests/EngineErrorMappingTests.swift` and a new `Tests/MCAppTests/FailureCardTests.swift`.
- Rewrite the out-of-memory copy, since the app has already freed its own memory. Map a chat 400 whose message contains "GPU memory" to `.enhancerOutOfMemory`. Show a canvas failure card with **Try Again** and **Dismiss**. A retried job is followed again. The failure card and the step bar share one bottom overlay stack (card above the step bar) rather than two independent bottom overlays, so a failure in a batch does not cover the progress of the next job.
- **Tests:**
  - A chat admission refusal maps to `.enhancerOutOfMemory`.
  - The same body on the image route is still `.badRequest`.
  - A followed job that fails takes the canvas.
  - Retry re-follows the job.

### U4. S06: canvas image bar (M, separate PR)

Spec: `docs/design-audit/specs/S06-canvas-image-bar.md`. No dependencies, but do it after U2 and keep I02's rule: `CanvasImageBar` sits directly after `SelectedImageView`, outside the step-bar `.overlay`. It renders for `model.canvasImage`, not `model.selectedImage`, so it stays under the kept image while a followed job runs. When U4 starts, change the spec's target line ("only when `model.selectedImage` is non-nil") and edit step 2 to match.

- Shows the prompt, facts, and the Export and Reuse actions under the canvas image. Export stays a byte copy with metadata (D37).

## Verification

- `swift test`, `swift format lint --strict` over all tracked Swift files, and the `xcodegen` + `xcodebuild` build.
- GUI smoke before each UI PR (`scripts/gui-smoke/run_smoke.py`, `AGENTS.md`).
- I02 acceptance 6 and 7: with the capture kit `ax dump` polling, "Select an image in the gallery, or generate one." never appears during a x3 batch, and the canvas ends on the newest gallery image.
- I03 acceptance 7 and 8 need no real memory failure: `FailureCardTests` scripts a 503 out-of-memory reply and renders the card in light and dark (`renderTheCardForReview`), and the two captures go on the PR with the message fully visible and contrast of at least 4.5:1. Only a live out-of-memory run stays unexercised; say so in the spec's Resolution section.
- On shipping each finding: update its README Status row, add its spec Resolution section, and put `Audit: <ID>` in the commit trailer and PR body.
