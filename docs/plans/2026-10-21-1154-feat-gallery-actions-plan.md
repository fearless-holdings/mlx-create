---
title: Gallery Actions and Filters - Plan
type: feat
date: 2026-10-21
topic: gallery-actions
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Gallery Actions and Filters - Plan

## Goal Capsule

- **Objective:** A user can find, select and clean up images in a collection's gallery without leaving the app: search by prompt, narrow by model and by LoRAs used, then delete, reveal, export or move a whole selection.
- **Product authority:** `docs/HLD.md` §8.9 and §10, amended by the decisions below (HLD update is the first step of delivery). Collections stay the only organising unit (D10, D35).
- **Open blockers:** none. Drop-PNG-to-restore, an All-collections view and a separate Gallery mode are not active scope.

---

## Product Contract

### Summary

The gallery gains ⌘/⇧-click multi-select and three new actions on the selection: Delete (to the Trash), Reveal in Finder and Export. Move to Collection already exists and extends to the selection. A search box matches prompt text, and filters narrow by model and by LoRAs used, all within the current collection.

### Problem Frame

The gallery shows every finished image in a collection, newest first, and offers only Reuse and Move. Removing an image, finding its file, getting a copy out of the library, or locating "the one with that prompt" means leaving the app for Finder. That is tolerable for a handful of images and breaks down at the scale the gallery is built for.

The model and LoRA stack an image was made with are already recorded on each image. Nothing lets the user filter by them, so "everything I made with this LoRA" has no answer in the app.

### Key Decisions

- **Delete moves files to the Trash and removes the library row.** Recoverable from Finder, no in-app undo. Governs R4, R5. (session-settled: user-directed — chosen over permanent delete with a confirm sheet and over Trash with in-app undo: recoverable without carrying undo state.)
- **Export always keeps the prompt and settings metadata.** No strip option, no per-export choice, no privacy setting, so no Settings window is needed. This reverses HLD §8.9's "export with or without metadata". Governs R7. (session-settled: user-directed — chosen over a per-export choice, two menu items, and an app-wide setting: "metadata really doesn't hurt in 95% of cases".)
- **Multi-select, not single-image actions.** Governs R1, R2, R3, R8. (session-settled: user-directed — chosen over single-image only and over single-now-multi-later: deleting or exporting dozens of images one at a time is the pain.)
- **Search matches prompt text only.** Model and LoRA are filters, not text. Governs R10. (session-settled: user-directed — chosen over also matching negative prompt, or model and LoRA names, as text.)
- **Several LoRA picks mean "used all of them".** Several model picks mean "any of them", since an image has one model. Governs R12, R13. (session-settled: user-directed — chosen over "any LoRA" and over an All/Any toggle: narrows as you add, matching how stacks are used.)
- **Tile actions and search/filters are one plan.** (session-settled: user-directed — chosen over splitting search into its own brainstorm.)

### Requirements

**Selection**

- R1. In the gallery, ⌘-click toggles an image in the selection and ⇧-click selects the range from the last-clicked image. A plain click selects only that image and shows it in the canvas, as today. ⌘-click and ⇧-click change only the selection and the range anchor, never the canvas.
- R2. The selection is separate from the image shown in the canvas. Actions act on the selection. A right-click on an unselected image replaces the selection with that image and makes it the anchor; a right-click on a selected image leaves the selection unchanged and acts on all of it.
- R3. Changing the search, a filter, or the collection removes images that are no longer visible from the selection, so an action never touches an image the user cannot see. If the image shown in the canvas is no longer visible, the canvas moves to the nearest visible image (older neighbour first), or to the empty state when none is visible, so the canvas and ⌘R never act on a hidden image.

**Actions on the selection**

- R4. Delete moves each selected image's PNG and thumbnail to the Trash and removes its library row. It is available from the tile menu and the Delete key, asks no confirmation, and has no in-app undo.
- R5. When the image shown in the canvas is deleted, the canvas shows the nearest remaining image, or the empty state when none remains.
- R6. Reveal in Finder selects the PNG files of the selection in a Finder window.
- R7. Export copies each selected PNG, with its prompt and settings metadata intact, to a location the user chooses: a save panel for one image, a folder panel for several. An existing file is never overwritten.
- R8. Move to Collection applies to the whole selection. Reuse prompt and Reuse all settings stay single-image and are unavailable when more than one image is selected.

**Search and filters**

- R9. The gallery panel has a search box and a filters control, always reachable without leaving the gallery.
- R10. Search matches the prompt text of images in the current collection.
- R11. The model filter lists the models used by images in the current collection that also match the current search and LoRA filter, shown by their display names. Models already picked stay listed. Choosing several shows images made with any of them.
- R12. The LoRA filter lists the LoRAs used by images in the current collection that also match the current search, model filter and the LoRAs already picked, including LoRAs since removed from the library. LoRAs already picked stay listed. Choosing several shows only images made with all of them. So no pick in either list can produce an empty gallery that the other criteria did not already produce.
- R13. Search, the model filter and the LoRA filter combine with AND. The gallery stays newest first and keeps paging, and one action clears them all.
- R14. Search and filters reset when the user switches collection.
- R15. When nothing matches, the gallery says so and offers the clear action instead of showing an empty grid. Whenever a search or filter is active, the filters control shows how many criteria are set and a Clear button is visible in the gallery header.
- R16. Images saved before LoRA support have no LoRA record. They show when no LoRA filter is set and match no LoRA filter.
- R17. Delete skips images whose job is queued, running or paused, and the result says how many were skipped and why. (session-settled: user-directed — chosen over letting the job regenerate and over shrinking the job: the executor finishes a job by counting its saved images, so deleting one would trigger an extra generation.)
- R18. A status line under the grid shows "N selected", or "N of M selected" when the selection is smaller than the M images matching the current search and filters (for example after ⌘A on loaded pages only). It also holds the last Delete result (deleted, skipped because their job is unfinished, failed) until the next action. While a delete of more than about 50 images runs, it shows progress and Delete, Export, Move and the filter controls are disabled; the grid stays visible and scrollable.

### Key Flows

- F1. Find and remove
  - **Trigger:** The user wants to clear out experiments made with one LoRA.
  - **Steps:** Opens the LoRA filter and picks the LoRA. The grid narrows. ⌘-click and ⇧-click select the images to remove. Delete sends them to the Trash and the grid updates.
  - **Covered by:** R1, R3, R4, R12, R13

- F2. Export a set
  - **Trigger:** The user wants a batch of finished images outside the app.
  - **Steps:** Searches a prompt phrase, ⇧-clicks a range, chooses Export, picks a folder. Files land with their metadata.
  - **Covered by:** R1, R7, R10

### Acceptance Examples

- AE1. **Covers R3, R4.** Given six images are selected and a model filter hides four of them, when the user presses Delete, then only the two visible images are trashed.
- AE2. **Covers R12.** Given image A used LoRAs X and Y, image B used only X, and the user picks X and Y in the LoRA filter, then only A shows.
- AE3. **Covers R16.** Given an image saved before LoRA support, when any LoRA is picked in the filter, then the image does not show; with no LoRA filter it shows normally.
- AE4. **Covers R5.** Given the canvas shows image 5 of 20 and image 5 is deleted, then the canvas shows the neighbouring remaining image.
- AE5. **Covers R7.** Given the destination already holds a file with an exported name, then the export keeps both files.
- AE6. **Covers R14.** Given a search term is typed in collection A, when the user switches to collection B, then B shows its full gallery with the search cleared.
- AE7. **Covers R11, R12.** Given model M1 images used only LoRA X and model M2 images used only LoRA Y, when the user picks M1, then the LoRA list shows X and not Y. When the user instead picks LoRA Y, the model list shows M2 and not M1, and Y stays listed.

### Scope Boundaries

**Deferred for later**

- Drop-a-PNG-to-restore, including restoring a trashed image's library row.
- An All-collections view and a separate full-window Gallery mode (HLD open question, D33).
- Searching negative prompts, model names or LoRA names as text.
- A metadata-strip option on export and a Settings window to hold it.
- Prompt history, a cover picker, tags, ratings and smart collections (D10, D35).

**Outside this unit**

- Reuse seed as its own action: Reuse all settings already restores the seed.

### Dependencies / Assumptions

- `docs/HLD.md` is amended before any code (AGENTS.md): the export decision reverses §8.9, and selection, Trash delete and gallery filters need a decision-log entry (next free ID is D37).
- Today the gallery selects one image only, and image delete, reveal, export, prompt search and filters do not exist (verified in `Sources/MCApp/GalleryView.swift`, `Sources/MCApp/GalleryCollectionView.swift`, `Sources/MCLibrary/LibraryStore.swift`).
- Each image records its model id and LoRA list (name, sha256, weight) inside its settings; the prompt is a column of its own. LoRA identity for the filter is assumed to be the sha256, so a renamed LoRA stays one entry.
- Models and LoRAs are recorded per image only inside its settings JSON. Making them filterable at the paged gallery's scale is a planning decision.

### Outstanding Questions

**Deferred to Planning**

- The filters control's form (popover, menu or inline chips) and the keyboard map beyond the Delete key and ⌘A. Escape is not handled.

### Sources / Research

- Existing gallery tile menu and accessibility actions: `Sources/MCApp/GalleryView.swift`.
- Single selection and the AppKit grid bridge: `Sources/MCApp/AppModel.swift`, `Sources/MCApp/GalleryCollectionView.swift`.
- Image rows, collection move, paged query: `Sources/MCLibrary/LibraryStore.swift`; per-image settings and LoRA record: `Sources/MCLibrary/Models.swift`.
- Only existing Finder reveal (LoRA files): `Sources/MCApp/AppModel+LoRA.swift`.
- Collections and move semantics: `docs/plans/2026-10-20-1423-feat-collections-plan.md`.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Filters read two indexed sources, not the settings JSON.** Migration `v7-gallery-filters` adds `image.model_id` and table `image_lora(image_id, sha256, name)`, backfilled from `settings`, and indexes `(collection_id, model_id, created_at)` and `image_lora(sha256)`. Every backfill JSON read is guarded with `json_valid(settings)`: a row where it is 0 gets NULL `model_id` and no `image_lora` rows, because SQLite raises on malformed JSON and one bad row must not fail the migration (the store already decodes such rows as `ImageSettings.unreadable`). `saveImage` writes both. Old rows with no `loras` get no join rows (R16). Governs R11, R12, R16.
- KTD2. **Prompt search is an external-content FTS5 table over `image.prompt`, kept in sync by triggers**, backfilled in `v7`. Matching is on the prompt column only (R10). The query is built by splitting the user's text into tokens, quoting each so FTS operators cannot error, and prefix-matching the last token, so "cat" finds "catalog" and results narrow as the user types. U1 probes FTS5 first; if the bundled SQLite lacks it, stop and report before building on it.
- KTD3. **One `GalleryQuery` value (collection, search text, model ids, LoRA hashes) feeds every gallery read**: first page, next page, reload, and the check on a newly saved image. Offset paging stays; the query adds SQL predicates, so offsets stay correct. Delete, move and any filter change bump `galleryRevision`.
- KTD4. **Selection model.** `AppModel.gallerySelection: Set<UUID>` plus an anchor id for ⇧-range; the existing `selection` keeps driving the canvas and queue jobs. A plain click sets both. After every `galleryImages` replacement, the set is intersected with loaded ids (R3). `canReuse` means exactly one image selected; ⌘. never reads the set.
- KTD5. **Delete = per-image unit**: skip if its job is unfinished (R17); trash PNG, trash thumbnail, delete the row in one write; if the row write fails, put the files back from their Trash URLs. A missing file counts as already gone. A volume without Trash leaves the image and reports it. After the loop, the canvas moves to the nearest surviving neighbour (older first) before the removal is applied (R5). The same neighbour rule serves search, filter and collection changes (R3).
- KTD6. **Export is a byte copy** (`FileManager.copyItem`), never an ImageIO re-encode, so the `parameters` and `mlx-create` chunks survive (R7). Name clashes get a numeric suffix. It does not copy `LibraryStore`'s delete-source-on-clash logic.
- KTD7. **Side effects sit behind injected closures on `AppModel`** (trash, reveal, save/folder panel), the same seam style as `LibraryStore.beforeRowInsertHook`. Production wires `FileManager.trashItem`, `NSWorkspace.activateFileViewerSelecting` and AppKit panels.
- KTD8. **A newly saved image is prepended only if it matches the active `GalleryQuery`**, checked through the same SQL predicate. Governs R13.
- KTD9. **Move to Collection becomes `moveImages(ids:toCollection:)`, one transaction**, still changing only `collection_id` (D35). Governs R8.

### Assumptions

- Bundled macOS SQLite provides FTS5 (GRDB's checkout is absent here, so U1 verifies).
- ⌘A selects loaded pages only. Deletes over about 50 images show a progress indicator and ask no confirmation.
- `trashItem` throws a distinguishable error for a missing file and for a volume with no Trash.

### Risks

- Migration backfill over a large library: runs once inside `v7`; U2 tests it from a v6 database with legacy rows.
- Gallery keyboard handling inside `NSCollectionView` can swallow keys meant for the prompt field; U5 limits Delete and ⌘A to gallery focus.

### System-Wide Impact

`selection` is read by queue strip, canvas, ⌘R and ⌘.; KTD4 leaves those untouched. `galleryRevision` guards every reload path.

---

## Implementation Units

| U-ID | Title | Files | Depends on |
|---|---|---|---|
| U1 | HLD D37 + FTS5 probe | `docs/HLD.md`, `Tests/MCLibraryTests` | none |
| U2 | Migration v7, query, search/filter store API | `LibraryStore.swift`, `Models.swift` | U1 |
| U3 | Store delete, move-many, export copy | `LibraryStore.swift` | U2 |
| U4 | AppModel selection, query state, actions | `AppModel*.swift` | U3 |
| U5 | Gallery UI: multi-select, menu, keys, search, filters | `GalleryView.swift`, `GalleryCollectionView.swift` | U4 |

### U1. HLD amendment and FTS5 probe

- **Goal:** Record the decisions before code (AGENTS.md) and prove FTS5 works.
- **Requirements:** R7, R4, R17.
- **Files:** `docs/HLD.md` (add D37: multi-select; Trash delete skipping unfinished jobs; export always keeps metadata, amending §8.9; gallery search and filters; fix §8.9 gallery bullets), a probe test in `Tests/MCLibraryTests`.
- **Test scenarios:** creating an FTS5 virtual table and matching a row in a temp GRDB database succeeds.
- **Verification:** probe passes; HLD diff reads consistently.

### U2. Migration v7, `GalleryQuery`, search and filter reads

- **Goal:** Make filters and search queryable at scale.
- **Requirements:** R10-R13, R16; KTD1-3.
- **Files:** `Sources/MCLibrary/LibraryStore.swift`, `Models.swift`, new `Tests/MCLibraryTests/GalleryFilterTests.swift`.
- **Approach:** add `GalleryQuery`; `recentImages(query:limit:offset:)`; `galleryFacets(query:)` returning models (with family name) and LoRAs (library name, else newest image's name). Each list is computed from the images matching the query's other criteria: the model list ignores the model selection (picks stay listed and "any" can widen), the LoRA list applies the model filter, search and the already-picked LoRAs ("all" narrows co-use) and keeps the picks listed. The facets are recomputed on every query change and after delete, move and each saved image; `image(id:matches:)`; `saveImage` fills `model_id` and `image_lora`. Never edit earlier migrations.
- **Test scenarios:** migrate from v6 with legacy rows (some with LoRAs, some without, one with malformed settings JSON that must not abort the migration) and assert backfill; AE2 (X+Y picked returns only A); AE3; several models return the union; search is case-insensitive, prefix-matches the last word, and text containing FTS operator characters (quotes, `-`, `*`, `AND`) does not error; filters and search combine; newest-first paging with limit+1 under a filter; facet lists narrow with search, the other facet and the picks (AE7), picked values stay listed, and no listed option yields zero results.
- **Verification:** `swift test --filter MCLibraryTests`.

### U3. Store delete, move-many, export

- **Goal:** Safe file and row operations.
- **Requirements:** R4, R5, R7, R8, R17; KTD5, KTD6, KTD9.
- **Files:** `LibraryStore.swift`, tests in `LibraryStoreTests.swift`, `CollectionTests.swift`.
- **Approach:** `deleteImages(ids:trash:)` returning per-id outcome (deleted, skippedActiveJob, failed) with an injected trash function; `moveImages`; `exportImages(ids:to:)` returning outcomes.
- **Test scenarios:** deleted image loses row, PNG and thumbnail (via fake trash); AE1-style partial failure leaves the failing image intact; row-write failure restores files; missing file still removes the row; image of a queued/running/paused job is skipped (R17); deleting a finished job's image leaves the job done; export keeps both files on a name clash (AE5) and the copy reads back through `MetadataCodec.read`; moveImages moves all or none.
- **Verification:** `swift test --filter MCLibraryTests`.

### U4. AppModel selection, query state and actions

- **Goal:** App-level behavior for R1-R18.
- **Requirements:** R1-R3, R5, R8, R9, R13-R15, R17, R18; KTD3, KTD4, KTD7, KTD8.
- **Files:** `AppModel.swift`, `AppModel+Collections.swift`, new `AppModel+GalleryActions.swift`, `Tests/MCAppTests/GalleryActionsTests.swift`.
- **Approach:** `gallerySelection`, anchor, `galleryQuery`, facets; toggle/range select; `deleteSelected`, `revealSelected`, `exportSelected`, `moveSelected`; reset query on collection switch (R14); prune selection on every list change; neighbour selection before removal; query-checked `prependImage`; injected side-effect closures. Tests that call refresh first `await model.start()`.
- **Test scenarios:** AE1 (hidden selected images are not trashed); AE4 (canvas moves to neighbour; empty state when none left); a filter or search that hides the canvas image moves the canvas to the nearest visible image (R3); AE6; a save during a filtered view does not appear if it doesn't match; a stale page after a filter change is discarded; ⌘R disabled with 2 selected; delete summary text counts deleted, skipped, failed; the "N of M selected" figures for a partial selection (R18).
- **Verification:** `swift test --filter MCAppTests`.

### U5. Gallery UI

- **Goal:** The visible controls.
- **Requirements:** R1, R2, R4, R6-R9, R15, R18; KTD4.
- **Files:** `GalleryView.swift`, `GalleryCollectionView.swift`, `MainWindow.swift` if a command is added.
- **Approach:** ⌘/⇧-click via modifier flags with the anchor; the grid's `appliedSelection` becomes a `Set<UUID>` and each update reconfigures only the symmetric difference, so a single click still touches at most two items. Right-click: the coordinator returns a context menu for the clicked index path (`NSCollectionView` menu handling), applying R2's selection rule before calling the same AppModel actions as the tile menu. The tile menu gains Delete, Reveal, Export on the selection. Delete key and ⌘A are handled only when the gallery has focus. A search field plus a filters popover (models any, LoRAs all) with a criteria count and a Clear button (R15); "No matches" empty state; the status line from R18 under the grid; matching accessibility actions; Export uses a save panel for one image and a folder panel for several.
- **Test expectation: none for the AppKit view code.** Behavior is covered in U4. Build with `xcodegen generate` and `xcodebuild`, launch the app and exercise select, delete, filter and export; the user tests the GUI.

---

## Verification Contract

- `swift test` (about 40 s; past 2 minutes it is hung, then `pkill -f swiftpm-testing-helper; pkill -f swift-test` and bisect with `--filter`).
- `xcodegen generate` then `xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build`, then launch and exercise the gallery against real saved images.

## Definition of Done

- R1-R18 and AE1-AE6 are true in the running app.
- D37 is in `docs/HLD.md`; no stale gallery wording remains.
- Existing paging, move and collection tests still pass.
- No scratch code or probe-only helpers are left in the diff; the FTS5 probe remains only if it guards a real behavior.
