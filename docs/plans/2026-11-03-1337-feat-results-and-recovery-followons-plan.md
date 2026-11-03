---
title: "Results and Recovery Follow-ons: Enhance Provenance, Queue Cells, LoRA Rejection, Gallery Arrows - Plan"
type: feat
date: 2026-11-03
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Results and Recovery Follow-ons: Enhance Provenance, Queue Cells, LoRA Rejection, Gallery Arrows - Plan

## Goal Capsule

- **Objective:** After pressing Generate, a user can tell their queued jobs apart, recover from a rejected LoRA in one click, step through a batch with the arrow keys, and trust that an image's saved "original prompt" is the prompt it was really enhanced from.
- **Means:** The four remaining post-Generate audit findings (I09, I05, I04, I08), executed from their specs in `docs/design-audit/specs/`, as three PRs ordered by cost of delay (KTD1).
- **Authority:** `docs/HLD.md` decisions, then this plan, then the specs. The specs describe commit `633e737`; where a spec's anchors disagree with `main`, `main` wins (KTD2).
- **Execution profile:** Three PRs. PR1 (tracker fix, I09), PR2 (I05, then I04), PR3 (I08). PR2 waits on PR1 for merge order only (KTD3). PR3 waits on nothing for code; its README row and Progress count are recomputed from the landed README when it rebases (KTD1). The implementer also ships each PR.
- **Stop conditions:** Stop and ask if a unit needs a new `D*` decision, if a control name in the audit README section 13 would change, or if a file would pass the 8,000-token budget that `scripts/check-file-size.mjs` enforces.

---

## Product Contract

### Summary

Ship I09, I05, I04 and I08, the findings still open in the audit's results-and-recovery cluster, and correct the audit tracker, which still lists I02, I03 and S06 as in progress though #27 and #28 merged. Window structure (S02 to S05), the LoRA and gallery-mode decisions (S07 to S09) and the visual layer wait for a later round.

### Problem Frame

The first-run path and the results-and-recovery core are on `main`. The moment after Generate still has four gaps. Every queue cell is an identical grey square, and failed or cancelled cells pile up under a header that says "Queue empty". A LoRA the engine rejects ends in a message with a raw engine model id and a fix that takes three clicks and a scroll. A batch can only be reviewed by clicking each thumbnail, and VoiceOver reads its tiles identically. And after Enhance, the "original prompt" stays attached when the user then writes something unrelated, so every later image's saved metadata names a prompt it was not made from. Saved metadata cannot be repaired afterwards, which is why that last gap goes first.

### Requirements

**Enhance provenance (I09)**

- R1. After Use This Prompt, the original prompt stays recorded only while the prompt still shares a word of four or more letters with the accepted enhancement, and is dropped when the prompt is emptied or becomes unrelated.
- R2. The Enhance card's buttons say what they do: Regenerate, Discard and Use This Prompt on a ready card, Dismiss and Try Again on a failed one. The original-prompt box offers Restore, which puts the original text back and clears the provenance.

**Queue (I05)**

- R3. Each queue cell shows its status in words, the job's prompt snippet, and progress. Only the status symbol carries colour, and the status text meets 4.5:1 contrast in light and dark (the prompt and progress lines stay `.secondary` until V02, as the I05 spec has them).
- R4. The queue header never says "Queue empty" while cells are on screen. It reports waiting jobs while one runs and the finished count when only failed or cancelled cells remain. A Clear button appears when such cells are shown.
- R5. A failed or cancelled cell can be removed on its own or all at once. Removal hides the cell without changing the job, survives a relaunch, and does not hide the job again after it is retried.

**LoRA rejection (I04)**

- R6. Failure messages about LoRAs name no engine model id.
- R7. A failed job that cannot be retried and carried LoRAs, at least one of which is still on the composer stack, offers Remove LoRAs from Stack on its failure card. The button takes those LoRAs off the stack, says so in the stack notice, and returns the canvas to the kept image.

**Gallery (I08)**

- R8. With the grid focused, the arrow keys select the previous, next, or row-above and row-below image exactly like a plain click, stop at the ends without wrapping, and scroll the image into view.
- R9. Each gallery tile's accessibility label carries its prompt, pixel size and seed as plain integers, so tiles of one batch differ.

**Tracker and contract**

- R10. The audit README's Status rows, counts and date match what has shipped, and each shipped finding has a Resolution section in its spec.
- R11. The control names the GUI smoke finds (audit README section 13) keep their names.

### Key Decisions

- **Results and recovery ships before window structure.** (session-settled: user-approved — chosen over the audit README section 3 order S05, S04, S03, S02: the post-Generate gaps cost more per user than window structure.) Governs R1 to R9.
- **I09 ships first.** (session-settled: user-approved — chosen over leading with I05, the higher-ranked finding: stale provenance writes wrong metadata into saved files that cannot be repaired later.) Governs R1.
- **I04 is in this round although rare.** (session-settled: user-approved — chosen over holding it: its dependency shipped and it is small.) Governs R6, R7.

### Success Criteria

- The audit README's walkthrough (e3) for a LoRA mismatch drops from "3 + scroll" clicks to 2, and once the grid has focus, walkthrough (b) lets a user step through a batch with the arrow keys alone.
- No image saved after the prompt stops sharing a word of four letters or more with the accepted enhancement records an original prompt.

### Scope Boundaries

- **Not in this plan:** S02 to S05 (the next round), S07 to S09 (S08 and S09 need your D34 and D33 decisions first), I06 (deferred until a live engine kill can be staged), and V01, V02, V05, V06.
- **Considered and not built:**
  - Storing dismissals in the database. A view preference is enough, because the job rows must not change; evidence to change: a request to sync dismissals across machines or to keep them per collection.
  - A fuzzier similarity test for provenance than shared words. Losing provenance is harmless (an empty field means a typed prompt), while keeping a wrong one records a falsehood; evidence to change: users reporting lost provenance after light edits.
  - Making the failure card's Dismiss also remove its strip cell. Dismiss returns the canvas to the kept image and Remove hides the cell. Joining them would make one button do two jobs.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Three PRs, by cost of delay and file overlap.** PR1 is I09 with the tracker fix. PR2 is I05 then I04, which share the failed-job experience (`JobItem`, `AppModel+Projection.swift`, the failure card). PR3 is I08, which shares no source file with the others. I05 and I09 both add stored state to `Sources/MCApp/AppModel.swift`, so PR2 waits on PR1 (KTD3). All three PRs edit `docs/design-audit/README.md`: each changes only its own Status row, and re-reads the Progress line on `main` to recompute the count just before it merges. Once all three land it reads 16 of 28 done, 1 deferred, 2 blocked, 9 open.
- KTD2. **`main` wins over the specs' anchors.** Anchor every edit by symbol, not line. Differences found when planning:
  - `selection = canvasFallbackImageID` in I05 and I04 becomes `dismissFailureCard()` in `Sources/MCApp/AppModel+Selection.swift`, which keeps the fallback only while it is still in the gallery.
  - I09's two reuse sites for `originalPrompt` now live in `Sources/MCApp/AppModel+Reuse.swift`, not `AppModel.swift`.
  - I09 needs no edit to `AppModel+DropRestore.swift` or `AppModel+PromptHistory.swift`: the accepted-enhancement text is read only while `originalPrompt` is non-nil, and every site that sets `originalPrompt` non-nil (accept, the two reuse paths) sets it too.
  - `LoRAExecutorTests.engineRejectingALoRANamesTheLoRAAndModelAndIsNotRetryable` has a name that states the behavior I04 removes; rename it with the assertion flip.
  - `job.request.loras` holds only the user's LoRAs. The executor adds always-on LoRAs at run time and never stores them (D44, `Sources/MCGeneration/Executor.swift`), so the I04 notice can never name one.
- KTD3. **`AppModel.swift` has about 470 tokens of headroom** (about 7,530 of the 8,000 the pre-commit ratchet enforces). Only stored properties, the init line and a one-line `didSet` change go in it; every function goes in an extension file. Before each PR, run `node scripts/check-file-size.mjs <files the PR changed>`, the same ratchet the pre-commit hook runs, and compare `wc -c Sources/MCApp/AppModel.swift` (bytes ÷ 4) with the figure above. `--all` also lists `Tests/MCLibraryTests/LoRALibraryTests.swift` (about 7,976 tokens) and exits 1 on a clean branch, so it is not a gate. If a PR would pass the budget, move a cohesive block of methods out first, as I02 did with `AppModel+Reuse.swift`.
- KTD4. **Dismissal is a view preference** in `UserDefaults` (`dismissedQueueJobIDs`), pruned on every reload against failed and cancelled jobs of all collections. A retried job leaves those states, is pruned, and shows again if it fails again. Precedent: the D29 pause flag.
- KTD5. **Provenance heuristic stays the spec's word-overlap rule.** Words are lowercase runs of letters and digits with four or more characters. A script written without spaces (Chinese, Japanese) forms one long word, so its first edit drops the provenance. Accepted: the loss is benign (R1's rationale) and the enhancer packs write English [INFERENCE: `docs/lld/enhancer.md` does not state the output language].
- KTD6. **I08's move arithmetic is a pure function** in `Sources/MCApp/GallerySelection.swift`, the file that already holds the click rules, so the clamp-at-the-ends rule is unit-tested without AppKit. Key-code handling stays in `GalleryCollectionView` and is checked live.
- KTD7. **Verify the grid with a gallery taller than its panel.** I08 adds a `columns` field to `GalleryLayout.fit(width:)`, the function behind the V04 bug that showed one column once a scroller appeared (`docs/solutions/developer-experience/nscollectionview-flow-layout-fit-before-the-layout-pass.md`). Use at least 12 images, not the spec's 6.

### Assumptions

- The GUI smoke runs on this Mac with a built-in display and mlx-create quit (`AGENTS.md`). Where it cannot run, the PR says so and does not count it as a pass.
- I09 and I05 live checks use a throwaway home with a symlinked FLUX.2 klein 4B and the Gemma enhancer (`docs/solutions/developer-experience/launch-app-with-empty-library-for-first-run-testing.md`). Nothing needs downloading.

---

## Implementation Units

### PR1: Tracker fix and Enhance provenance

Waits on: nothing.

### U1. Correct the audit tracker

- **Goal:** The tracker states what has shipped (R10).
- **Requirements:** R10.
- **Dependencies:** none.
- **Files:** `docs/design-audit/README.md`.
- **Approach:**
  - In section 2, change the I02 and I03 rows to `done ([#27](https://github.com/fearless-holdings/mlx-create/pull/27))` and the S06 row to `done ([#28](https://github.com/fearless-holdings/mlx-create/pull/28))`.
  - Rewrite the Progress line to 12 of 28 done, 1 deferred, 2 blocked, 13 open, dated 2026-11-03. U2 then bumps it to 13 done for I09.
  - Section 3 item 4 keeps its order; its remaining items are I04, I05, I08, I09.
- **Test expectation:** none -- documentation only.
- **Verification:** Read the table: the row statuses, the count and `git log --grep='Audit: '` agree.

### U2. I09: Enhance card labels, Restore, and provenance that does not go stale

- **Goal:** Honest card buttons, an undo for Use This Prompt, and no wrong "original prompt" in later images (R1, R2).
- **Requirements:** R1, R2, R11.
- **Dependencies:** U1 (same README edit).
- **Files:** `docs/HLD.md` (section 8.8, line "with Accept, Revert and Regenerate"), `Sources/MCApp/AppModel.swift`, `Sources/MCApp/AppModel+Enhance.swift`, `Sources/MCApp/AppModel+Reuse.swift`, `Sources/MCApp/EnhanceResultCard.swift`, `Sources/MCApp/GenerationPanel.swift`, `Tests/MCAppTests/EnhanceTests.swift`, `docs/design-audit/specs/I09-enhance-card-actions-and-provenance.md` (Resolution), `docs/design-audit/README.md` (row, count).
- **Approach:** Follow the spec's edit steps, with these deltas (KTD2, KTD3):
  1. Edit HLD 8.8 first, as `AGENTS.md` asks. Replace the sentence "a result card with Accept, Revert and Regenerate. After Accept, the replaced prompt stays visible read-only under the editor." with one that names Use This Prompt, Discard and Regenerate, says the replaced prompt shows read-only after Use This Prompt with a Restore button that puts it back, and says the box goes once the prompt no longer shares a word of four letters or more with the accepted enhancement. This is wording only; no `D*` changes.
  2. In `AppModel.swift` add only the stored `acceptedEnhancedPrompt` and replace the `prompt` `didSet` body with one call to a helper in `AppModel+Enhance.swift`. The helper and `significantWords(_:)` live in the extension.
  3. Set `acceptedEnhancedPrompt` in `acceptEnhance()` (before `prompt = result.prompt`) and in the two reuse paths in `AppModel+Reuse.swift` (`acceptedEnhancedPrompt = originalPrompt == nil ? nil : prompt`).
  4. Add `restoreOriginalPrompt()` to `AppModel+Enhance.swift`.
  5. Rename the three Enhance buttons and add Restore to `originalPromptField`. Change that container from `.combine` to `.contain`, so the button stays reachable.
- **Execution note:** Write the three provenance tests first, since the spec's rule is easy to implement as the opposite of its intent.
- **Patterns to follow:** `EnhanceTests.acceptReplacesThePromptAndRecordsTheTextItReplaced` for the harness (`enhancerHarness(chat:)`, `readyKrea`, `chatReply`).
- **Test scenarios:**
  - After accepting "a misty lighthouse at dusk" (replacing "a lighthouse"), setting the prompt to "a misty lighthouse at dawn" leaves `originalPrompt == "a lighthouse"`.
  - Setting the prompt to "a paper boat on a puddle" makes `originalPrompt == nil`.
  - An edit that keeps exactly one shared word of four letters keeps the provenance, and the comparison ignores case ("LIGHTHOUSE").
  - `restoreOriginalPrompt()` gives `prompt == "a lighthouse"` and `originalPrompt == nil`, and a second call changes nothing.
  - Integration: after accept, then an unrelated prompt, then Generate, the enqueued job's request has `originalPrompt == nil`. This is the saved-metadata bug itself.
  - Reusing an image's settings that carry an original prompt restores it, and editing that prompt to something unrelated drops it.
  - Every existing `EnhanceTests` test passes unchanged.
- **Verification:**
  - `ax dump` of a ready card shows Regenerate, Discard and Use This Prompt, and no Revert or Accept.
  - After Use This Prompt and an unrelated prompt, the "Original prompt" box is gone.
  - After Use This Prompt and Restore, the prompt is back to the original.
  - Captures `I09_card_small_light.png` and `I09_original_small_light.png` go on the PR.
  - GUI smoke exits 0.

### PR2: Queue cells and LoRA rejection

Waits on: PR1, merge order only (KTD3).

### U3. I05: queue cells you can tell apart, an honest header, Clear

- **Goal:** Cells that show what each job is, a header that matches them, and removable failed cells (R3, R4, R5).
- **Requirements:** R3, R4, R5, R11.
- **Dependencies:** U2 merged (KTD3). Uses `selectJob` from I02.
- **Files:** `Sources/MCApp/AppModel.swift`, `Sources/MCApp/AppModel+Projection.swift` (`reloadQueue`), `Sources/MCApp/AppModel+Queue.swift`, `Sources/MCApp/QueueStripView.swift`, `Tests/MCAppTests/QueueDismissTests.swift` (new), `docs/design-audit/specs/I05-queue-strip-legible-cells.md` (Resolution), `docs/design-audit/README.md`.
- **Approach:** Follow the spec's target behavior and edit steps, with these deltas:
  1. `AppModel.swift` gets only the stored `dismissedJobIDs`, its defaults key and the init line (KTD3). `dismissJobs(_:)` and `finishedJobIDs` go in `AppModel+Queue.swift`.
  2. When the dismissed job is the selection, return through `dismissFailureCard()` rather than assigning the fallback id (KTD2).
  3. Prune against failed and cancelled jobs of all collections, so a dismissal in another collection survives (KTD4).
  4. Keep the cell's Button, context menu, accessibility actions and `.onKeyPress` (⌥↑ and ⌥↓). Put the Remove button beside the cell Button, not inside its label.
- **Patterns to follow:** `QueuePauseTests.pausedHarnessWithTwoJobs` and `AppHarness.relaunch(script:)`; `ImageCell`'s `.overlay(alignment: .topTrailing)` in `Sources/MCApp/GalleryView.swift`.
- **Test scenarios:**
  - Cancel a queued job and dismiss it: it leaves `queueJobs`, the store still lists it as cancelled, and after `relaunch` with the same defaults it stays hidden.
  - Dismiss a failed job and retry it: it reappears as queued, and when it fails again it shows again (the id was pruned).
  - Dismiss a cancelled job in collection A, switch to B and back: it stays hidden, and a failed job in B that was dismissed earlier stays hidden too.
  - Clear removes every failed and cancelled cell and leaves paused, queued and running cells alone.
  - Dismissing the failed job whose card is on the canvas leaves `selectedFailedJob == nil` and the kept image on the canvas.
- **Verification:**
  - `ax dump` with two queued jobs of different prompts shows each cell's prompt start. With a cancelled cell on screen it shows no "Queue empty" text.
  - Removing the cancelled cell hides it, and a relaunch keeps it hidden.
  - `contrast.py` on the status text of a failed and a cancelled cell is at least 4.5:1, light and dark.
  - Captures `I05_strip_small_light.png` and `I05_strip_small_dark.png` go on the PR. Check the shorter strip (96 to 64 pt) at 1100×692 with the canvas above it.
  - GUI smoke exits 0.

### U4. I04: plain LoRA-rejection copy and Remove LoRAs from Stack

- **Goal:** A rejected LoRA tells the user what to do and offers the one-click fix (R6, R7).
- **Requirements:** R6, R7.
- **Dependencies:** U3 (same `Projection` and failure-card area; sequence only).
- **Files:** `Sources/MCGeneration/FailureMapping.swift`, `Sources/MCApp/ViewState.swift` (`JobItem`), `Sources/MCApp/AppModel+Projection.swift` (`placeholder`), `Sources/MCApp/CanvasView.swift` (`FailureCard`), `Tests/MCGenerationTests/LoRAExecutorTests.swift`, `Tests/MCAppTests/FailureCardTests.swift`, `docs/design-audit/specs/I04-lora-rejection-recovery.md` (Resolution), `docs/design-audit/README.md`.
- **Approach:** Follow the spec's copy and edit steps, with these deltas (KTD2):
  1. The four messages lose their model id. `modelID` stays on the enum cases.
  2. The button shows when `!job.canRetry` and at least one of the job's LoRAs is still on the composer stack, so it is absent for a user who already removed them by hand. `JobItem` carries both `loraIDs` and `loraNames`, as the spec has it. A missing-file failure is retryable, so it keeps Try Again and no Remove button.
  3. The stack notice names only LoRAs still on the stack when the button is pressed, so it never reads "Removed  from the stack". The button removes every LoRA the job carried: the engine's rejection does not say which one failed.
  4. The canvas returns through `dismissFailureCard()`.
  5. Flip the `LoRAExecutorTests` assertions to `!failure.message.contains(kreaModel)` and rename the rejection test.
- **Test scenarios:**
  - A 400 "no modules matching" with one stacked LoRA fails the job, not retryable, with `loraIDs` holding that LoRA's id. Removing it empties `loraStack`.
  - Two stacked LoRAs, one engine rejection: after the fix, both are off the stack, `loraNotice` names both in quotes, and `canvasImage` is the kept image.
  - A failed job that carried no LoRAs has empty `loraIDs` and no Remove button.
  - Each of the four LoRA messages names the LoRA or the limit and does not contain the model id.
  - `placeholder` fills `JobItem.loraIDs` and `loraNames` from `job.request.loras`, so they are non-empty for any job that carried LoRAs. The card's button appears only when `!canRetry` and a listed LoRA is still stacked: after the user removes the LoRA by hand, it is gone. The card's look is checked in the capture below.
- **Verification:** Capture `I04_card_light.png` on the PR. State that the engine rejection cannot be produced on demand with installed LoRAs, so the live path is unexercised.

### PR3: Gallery arrow keys

Waits on: nothing for code. The README row and Progress count rebase onto whatever of PR1 and PR2 has merged (KTD1).

### U5. I08: arrow keys in the gallery and distinct tile labels

- **Goal:** Review a batch from the keyboard, and let VoiceOver tell tiles apart (R8, R9).
- **Requirements:** R8, R9, R11.
- **Dependencies:** none.
- **Files:** `Sources/MCApp/GalleryCollectionView.swift`, `Sources/MCApp/GalleryView.swift` (`ImageCell`), `Sources/MCApp/GallerySelection.swift`, `Tests/MCAppTests/GalleryActionsTests.swift`, `docs/design-audit/specs/I08-gallery-keyboard-and-labels.md` (Resolution), `docs/design-audit/README.md`.
- **Approach:** Follow the spec's edit steps, with these deltas:
  1. Put the neighbour arithmetic in a pure function in `GallerySelection.swift` and have the coordinator's `moveSelection` call it (KTD6). With nothing selected, or a selection that is not an image id (a running job), an arrow selects the first image.
  2. Restructure `keyDown` so Delete, the arrows and `super` are each reached once.
  3. Keep the label prefix "Image: " and the prompt first: the smoke finds tiles by prefix plus a prompt token.
- **Patterns to follow:** `GalleryClick` and the other click rules already in `GallerySelection.swift`.
- **Test scenarios:**
  - Next and previous from the middle of ten ids return the neighbour.
  - Previous from the first and next from the last return no move (no wrap).
  - Down by a column count of 2 from index 6 of ten ids moves to index 8, and from index 9 (the last id) stays put.
  - Down from index 8 of ten ids clamps to index 9, the last id.
  - No selection, or a selection that is not in the list, returns the first id.
- **Verification:** With at least 12 images from one batch (KTD7), at 1100×692, `ax press` the first tile then `key code 124`: the canvas image changes and the ring moves right. `key code 125` moves it down a row. `ax dump | grep 'desc="Image: '` shows labels ending in `seed <digits>` that differ pairwise. GUI smoke exits 0.

---

## Verification Contract

| Check | Command | Applies to |
|---|---|---|
| Build | `swift build` | every PR |
| Tests | `swift test` (about 40 s; past 2 min is a hang: `pkill -f swiftpm-testing-helper; pkill -f swift-test`, then `--filter` per suite) | every PR |
| Format | `git ls-files '*.swift' \| xargs swift format lint --strict --configuration .swift-format` prints nothing | every PR |
| App build | `xcodegen generate` then `xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` | every PR |
| File budget | `node scripts/check-file-size.mjs <files the PR changed>` exits 0 (the pre-commit ratchet) | PR1, PR2 |
| GUI smoke | `python3 scripts/gui-smoke/run_smoke.py --models DIR --model-id ORG/NAME` (exit 2 is not run, never a pass) | PR1, PR2, PR3 |
| Live checks | capture kit `ax dump`, `contrast.py`, `cap.py shot` per unit's Verification | U2, U3, U5 |

## Definition of Done

- Every unit's test scenarios exist and pass, and the unit's live checks ran or the PR names what could not run.
- Each shipped finding has its README Status row updated, a Resolution section in its spec, `Audit: <ID>` in the commit trailer and PR body, and the README count and date bumped.
- `docs/HLD.md` section 8.8 carries the new Enhance wording in the same PR as U2.
- The control names in audit README section 13 are unchanged, and no file passed the size budget.
- No scratch scripts or temporary logging remain, and captures for the PRs are attached, not committed outside `docs/design-audit/screens/`.

## Deferred to Implementation

- Whether the 64 pt queue cell leaves the canvas and strip balanced at 1100×640. Judge it from the I05 captures.
- The exact placement of the Remove button against the cell's focus ring. Follow `ImageCell`, adjust from the capture.
- Whether Tab reaches the grid without a pointer. Delete already depends on the grid taking focus (`acceptsFirstResponder`), and the I08 spec has no focus ring. If a keyboard-only user cannot reach it, the PR says so; a focus ring and key-loop change are not part of this round.

## Sources and Research

- Specs at commit `633e737`: `docs/design-audit/specs/I09-enhance-card-actions-and-provenance.md`, `I05-queue-strip-legible-cells.md`, `I04-lora-rejection-recovery.md`, `I08-gallery-keyboard-and-labels.md`.
- Prior plan whose order this continues: `docs/plans/2026-11-02-1544-feat-results-and-recovery-plan.md`.
- Anchors re-checked on `main` at `8bcf5b2`: `selectJob`, `canvasImage`, `selectedFailedJob`, `dismissFailureCard` in `Sources/MCApp/AppModel+Selection.swift`; `FailureCard` in `Sources/MCApp/CanvasView.swift`; the I09 reuse sites in `Sources/MCApp/AppModel+Reuse.swift`; `GalleryCollectionView.keyDown`; D44 handling in `Sources/MCGeneration/Executor.swift`.
- Learning: `docs/solutions/developer-experience/nscollectionview-flow-layout-fit-before-the-layout-pass.md` (KTD7).
