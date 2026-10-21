---
title: "feat: Collection prompt history in the composer"
type: feat
date: 2026-10-21
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# feat: Collection prompt history in the composer

## Goal Capsule

- **Objective:** A user can bring back a prompt they used earlier in the current collection from the composer, without opening the gallery.
- **Means:** A per-collection history table written when a job is queued, read through a popover beside Enhance (KTD1, KTD3).
- **Product authority:** The Product Contract below. HLD D10 and §9 name `PROMPT_HISTORY` as deferred; this plan builds composer recall only, and the HLD gets decision D39 before any code (AGENTS.md).
- **Open blockers:** None.
- **Execution profile:** Library code is test-first; the popover is proven by a smoke run in the real app. Product Contract preservation: unchanged, except that the two Deferred-to-Planning questions are resolved in KTD2 and KTD4.

---

## Product Contract

### Summary

The composer gets a recent-prompts control beside the prompt box. Each Generate press records the prompt and negative prompt in the current collection's history. Picking an entry fills the prompt and negative prompt and changes nothing else.

### Problem Frame

Gallery search and Reuse prompt only reach prompts that produced a surviving image. A prompt whose job failed, was cancelled, or whose images were deleted cannot be found again, and recalling any prompt means leaving the composer for the gallery.

### Key Decisions

- **History serves quick re-use from the composer.** It is not a browse view, a draft undo, or a cross-collection list. (session-settled: user-directed — chosen over browse-and-search view and draft undo: the stated need is fast re-use at the composer.) Governs R1, R5.
- **An entry restores prompt and negative prompt only.** (session-settled: user-directed — chosen over prompt text only and full settings: settings re-use already exists as gallery Reuse settings.) Governs R4.
- **History is per collection.** (session-settled: user-directed — chosen over all-collections and a widen toggle: collections already carry their own defaults, D35.) Governs R5, R8.
- **Dedupe, a 100-entry cap and deletion-independence are agent defaults the user approved in the scope summary.** (session-settled: user-approved — proposed with tradeoffs surfaced, user confirmed the scope.) Governs R2, R3, R6.

### Requirements

**Recording**

- R1. Pressing Generate records the submitted prompt and negative prompt in the current collection's history; Enhance alone records nothing.
- R2. An entry whose prompt and negative prompt both match an existing entry moves that entry to the top instead of adding a second one.
- R3. Each collection keeps its 100 most recent entries; the oldest is dropped when a new one would exceed that.
- R6. Deleting, failing or cancelling images and jobs does not remove history entries.

**Recall**

- R4. Picking an entry fills the composer's prompt and negative prompt, and leaves model, size, steps, CFG, seed and LoRA stack unchanged.
- R5. A recent-prompts control beside the prompt box lists the current collection's entries, newest first, and can be filtered by typing.
- R7. Entries with an empty negative prompt restore an empty negative prompt, replacing whatever the composer holds.

**Lifecycle**

- R8. Switching collections shows that collection's history; deleting a collection (allowed only when empty, D35) deletes its history.
- R9. History persists across app relaunch.

### Acceptance Examples

- AE1. Covers R1, R6. Given a prompt whose job was cancelled before any image saved, when the user opens the recent-prompts control, then the prompt is listed.
- AE2. Covers R2. Given the user generates the same prompt and negative prompt twice, then the list shows one entry, at the top.
- AE3. Covers R4. Given the composer is set to a different model and steps, when the user picks an entry, then prompt and negative prompt change and model and steps do not.
- AE4. Covers R5, R8. Given two collections with different histories, when the user switches collection, then the control lists only the newly selected collection's entries.

### Scope Boundaries

Deferred or excluded:

- An All-collections history view or a widen toggle.
- Pinning, editing, renaming or per-entry delete, and a clear-all action.
- Recording Enhance results that were not generated.
- Restoring settings from an entry; gallery Reuse settings stays the way to do that.
- Collection cover picker (still deferred, D35).

---

## Planning Contract

### Key Technical Decisions

- KTD1. **History is its own table, `prompt_history`, created by migration `v8-prompt-history`.** A row is `(id, collection_id, prompt, negative_prompt)` with `id` an auto-increment integer and `collection_id` a cascading foreign key to `collection`. Recency is `id` order, so no timestamp is needed. Cascade gives R8's deletion for free, as `job` and `image` already do (`Sources/MCLibrary/LibraryStore.swift`). Governs R2, R3, R8, R9. Chosen over a JSON blob on `collection.defaults` because R2 and R3 are row operations.
- KTD2. **The entry records the text sent to the engine.** When an Enhance result was accepted, that is the enhanced prompt. The value comes from the `JobRequest` being queued (`prompt`, `negativePrompt` with nil stored as empty), so a family without negative-prompt support records an empty negative. Picking an entry sets `originalPrompt` to nil, because a recalled prompt is not an enhancement. Resolves the brainstorm's deferred question. Governs R1, R4, R7.
- KTD3. **Recording happens inside `LibraryStore.enqueueJob`'s write transaction.** Its only caller is `GenerationComposer.enqueue`, so a queued job always has an entry and a rejected empty prompt records nothing. Dedupe is delete-matching-then-insert, which also moves a repeat to the top; the cap then deletes rows beyond the newest 100 for that collection. Governs R1, R2, R3, R6.
- KTD4. **The control is a clock-icon button beside Enhance that opens a popover, with a filter field and the list.** The list is read from the store when the popover opens, so it is never stale and no per-collection refresh hook is needed. Filtering is an in-memory case-insensitive match over at most 100 entries, with no FTS. There is no keyboard shortcut (⌘E, ⌘R, ⌘. and ⌘↩ are taken). Resolves the brainstorm's deferred question. Governs R5, R8.
- KTD5. **Picking sets `prompt` before `negativePrompt` and `originalPrompt`.** The `prompt` setter clears `originalPrompt` when the prompt is blank (`Sources/MCApp/AppModel.swift`), so the order keeps provenance cleared deterministically. Governs R4, R7.

### Assumptions

None beyond the Key Technical Decisions; the scoping synthesis was confirmed.

### System-Wide Impact

- **Schema:** one new table and migration; existing databases upgrade with an empty history (existing jobs are not backfilled).
- **Hot path:** `enqueueJob` gains two small statements in a transaction it already holds.
- **Collection delete:** no change to eligibility rules; history rows cascade.
- **File-size ratchet:** `LibraryStore.swift` takes only the migration registration. All other code goes in new files to stay under the 8,000-token budget.

---

## Implementation Units

### U1. Record decision D39 in the HLD

- **Goal:** Make the HLD the source of truth before code, per AGENTS.md.
- **Requirements:** R1–R9.
- **Dependencies:** none.
- **Files:** `docs/HLD.md`.
- **Approach:**
  - Add decision D39 after D38: composer prompt history, per collection, recorded on queue, restores prompt and negative prompt, cap 100, dedupe by moving to top. Cite KTD2 and KTD3's rationale in one line each.
  - Update §9: the `PROMPT_HISTORY` entity gets its fields and `COLLECTION ||--o{ PROMPT_HISTORY` already exists; drop "prompt history" from the deferred wording in D10, D35 and §8.9 and from §13's v1.0 row if mentioned.
- **Test expectation:** none -- documentation only.
- **Verification:** the HLD names D39 and no section still lists prompt history as deferred.

### U2. Store: table, recording, listing

- **Goal:** Persist and read history per collection with dedupe and cap.
- **Requirements:** R1, R2, R3, R6, R8, R9; AE1, AE2.
- **Dependencies:** U1.
- **Files:** `Sources/MCLibrary/LibraryStore.swift` (register `v8-prompt-history` after `v7-gallery-filters`; call the recorder from `enqueueJob`), `Sources/MCLibrary/LibraryStore+PromptHistory.swift` (new: table creation helper, public `PromptHistoryEntry`, `promptHistory(collectionID:)`, private recorder), `Tests/MCLibraryTests/PromptHistoryTests.swift` (new).
- **Approach:**
  - Follow `Sources/MCLibrary/LibraryStore+InstalledModels.swift`: a static table-creation helper called from the migration, a public domain struct, a private row type.
  - `enqueueJob` calls the recorder inside its existing `dbQueue.write`, after the job insert succeeds.
  - Recorder: delete the collection's row with equal prompt and negative prompt, insert, then delete rows outside the newest 100 for that collection.
  - `promptHistory(collectionID:)` returns entries newest first.
- **Execution note:** Write the recording and cap tests first; they pin KTD3.
- **Patterns to follow:** `Sources/MCLibrary/LibraryStore+InstalledModels.swift`; temp-dir stores from `Tests/MCLibraryTests/LibraryStoreTests.swift` (`tempRoot()`, `request()`); `Tests/MCLibraryTests/GalleryFilterTests.swift` for migrating an old schema with `migrate(queue, upTo:)`.
- **Test scenarios:**
  - Enqueue one job: `promptHistory` returns one entry with that prompt and negative prompt.
  - Enqueue the same prompt and negative prompt twice with another prompt between them: three enqueues leave two entries, the repeated one first.
  - Same prompt with a different negative prompt: two entries.
  - Nil negative prompt stores as empty and equals an explicit empty one (dedupes).
  - Enqueue 101 distinct prompts: 100 remain and the first one is gone; the order is newest first.
  - Cap is per collection: filling collection A to 101 does not remove entries in B.
  - Cancel and fail a job, then delete its images: its entry remains (AE1).
  - `enqueueJob` that throws on a missing LoRA records no entry.
  - Delete an empty non-default collection with history: its rows are gone and other collections' rows remain.
  - Open a store migrated up to `v7-gallery-filters`, then open normally: the `prompt_history` table exists and is empty; reopening a store keeps entries (R9).
- **Verification:** `swift test --filter PromptHistoryTests` passes; `swift test` passes.

### U3. App model: load and apply

- **Goal:** Give the UI the current collection's entries and a pick action.
- **Requirements:** R4, R5, R7, R8; AE3, AE4.
- **Dependencies:** U2.
- **Files:** `Sources/MCApp/AppModel+PromptHistory.swift` (new), `Tests/MCAppTests/` (existing AppModel test target; add `PromptHistoryModelTests.swift`, following how current tests drive `AppModel`, with `await model.start()` first).
- **Approach:**
  - `promptHistory()` async reads `store.promptHistory(collectionID: currentCollection.id)`.
  - `applyPromptHistoryEntry(_:)` sets `prompt`, then `negativePrompt`, then `originalPrompt = nil` (KTD5), touching nothing else.
  - Filtering stays in the view layer.
- **Patterns to follow:** `AppModel.reusePrompt(of:)` in `Sources/MCApp/AppModel.swift`; collection access in `Sources/MCApp/AppModel+Collections.swift`.
- **Test scenarios:**
  - After `generate()` with a stubbed engine path used by existing tests, `promptHistory()` lists the prompt in the current collection.
  - Applying an entry changes prompt and negative prompt and leaves selected model, size, steps and guidance unchanged (AE3).
  - Applying an entry with an empty negative prompt clears a non-empty negative prompt in the composer (R7).
  - Applying an entry after an Enhance accept clears `originalPrompt`.
  - After `switchCollection(to:)`, `promptHistory()` returns only the new collection's entries (AE4).
- **Verification:** `swift test --filter PromptHistoryModelTests` passes.

### U4. Popover control in the generation panel

- **Goal:** The visible control: button, filter field, list, pick.
- **Requirements:** R4, R5, R7, R8; AE3, AE4.
- **Dependencies:** U3.
- **Files:** `Sources/MCApp/PromptHistoryPopover.swift` (new), `Sources/MCApp/GenerationPanel.swift` (button in `enhanceRow`).
- **Approach:**
  - Button with a clock symbol and the accessibility label "Recent prompts", placed in the Enhance row; always enabled, since the list is read on open (KTD4).
  - Popover pattern from `Sources/MCApp/ModelChip.swift` and `GalleryView`'s filter popover: filter text field at top, list below, each row showing the prompt (line-limited) and a secondary line for a non-empty negative prompt. Click picks and closes.
  - List loads on open through `promptHistory()`; an empty collection shows a plain "No prompts yet" line and an empty filter result shows "No matching prompts".
- **Execution note:** Prefer a runtime smoke over unit coverage; there is no view-testing convention in the repo.
- **Test expectation:** none -- SwiftUI view, covered by the smoke run below.
- **Verification:** build the app (`xcodegen generate`, then the `xcodebuild` command in AGENTS.md), launch it, generate with the smallest installed model or queue a job and cancel it, then check: the control lists the prompt, repeating it shows one row, a pick fills prompt and negative prompt while model and steps stay, switching collection shows that collection's list, and relaunching keeps the entries.

---

## Verification Contract

| Check | Command or action | Applies to |
|---|---|---|
| Library and model tests | `swift test` (about 40 s; past 2 minutes it is hung, see AGENTS.md) | U2, U3 |
| App build | `xcodegen generate`, then `xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` | U4 |
| Runtime smoke | Launch `build/Build/Products/Debug/mlx-create.app`; run the U4 verification path. After quitting, check `pgrep mlx-serve` for a stray engine | U4 |
| File-size ratchet | `node scripts/check-file-size.mjs` over changed files (budget 8,000 tokens) | U2–U4 |
| Churn check | `git diff -w --stat` after each edit tool use on existing Swift files; the format-on-save hook can reindent them | U2–U4 |

## Definition of Done

- All requirements R1–R9 hold, shown by the U2 and U3 tests and the U4 smoke run, including AE1–AE4.
- HLD D39 exists and no section lists prompt history as deferred.
- `swift test` and the Debug `xcodebuild` pass; the ratchet reports no over-budget file.
- No abandoned-attempt code, throwaway scripts or scratch files remain; `AGENTS.md`, `.codegraph/` and `opencode.jsonc` stay uncommitted.
- Tests pin behavior only (recording, dedupe, cap, cascade, apply), never wording or wiring.
