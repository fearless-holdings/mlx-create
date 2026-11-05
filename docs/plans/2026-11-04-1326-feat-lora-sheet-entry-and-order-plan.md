---
title: "LoRA Sheet: One Entry Point and an Opening Tab That Fits - Plan"
type: feat
date: 2026-11-04
execution: code
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
---

# LoRA Sheet: One Entry Point and an Opening Tab That Fits - Plan

## Goal Capsule

- **Objective:** A first-time user who wants a LoRA reaches the curated list, or Civitai, in one press of Add LoRA…, with no empty screen and no word to learn first (D43).
- **Means:** Build audit finding S07 from `docs/design-audit/specs/S07-lora-sheet-entry-and-order.md`, plus one exception for refused or duplicate drops (KTD3).
- **Authority:** `docs/design-audit/specs/S07-lora-sheet-entry-and-order.md` for edit steps, exact labels and acceptance checks; this plan wins where it deviates (KTD3). `docs/HLD.md` D34, D43 and D15 are unchanged in substance.
- **Execution profile:** one plain PR off `main`, not a stack (AGENTS.md reserves `gh stack` for two or more dependent PRs). It carries `Audit: S07` in the PR body and commit message, and the GUI smoke evidence.
- **Stop conditions:** stop and ask if the sheet cannot open on the chosen tab without new `AppModel` state (KTD1), or if `swift test` fails in a LoRA or Shelf suite.
- **Finishes the work:** the implementer ships the PR, then S08 stays blocked only on its D34 decision.

## Product Contract

### Summary

The LoRA section of the generation panel gets one Add LoRA… button. The LoRA sheet's tabs become Recommended, Your LoRAs, Civitai, and the sheet opens on the first tab that has something for the selected model. The empty Your LoRAs state gains two shortcuts to the other tabs.

### Problem Frame

Pressing Add LoRA… on a fresh install opens a sheet on "Installed" that says "No LoRAs yet." and offers only Import…. The curated shelf, the path D43 built so that a first-time user needs no LoRA knowledge, sits behind the second tab under a word, "Shelf", the user has to learn. The panel also carries a "Library…" link and an Add LoRA… button that open the same sheet.

### Requirements

**Entry point**

- R1. The panel's LoRA section has one **Add LoRA…** button, and its header is the plain text "LoRAs" with no link.

**Sheet tabs**

- R2. The sheet's segmented control reads **Recommended**, **Your LoRAs**, **Civitai**, in that order.
- R3. When no model is selected, the sheet opens on Your LoRAs, the only tab that works without one. Otherwise it opens on Your LoRAs when the library holds a LoRA that fits the selected model, else on Recommended when the shelf lists an entry for the selected family under the current NSFW opt-in, else on Civitai.
- R4. While the import summary lists refused or duplicate files, the sheet opens on Your LoRAs whatever R3 says, and shows the summary there even when the library is empty. Closing the sheet clears that summary, so R3 governs every later opening.
- R5. The empty Your LoRAs state offers **See Recommended LoRAs** and **Browse Civitai** under Import…. The first shows only when the shelf lists an entry for the selected family.

**Unchanged**

- R6. The shelf, its license sheet and tested scale (D43), Civitai browsing, the NSFW opt-in and blur (D15), and drop-to-import all behave as today, including a file dropped on the sheet whichever tab is showing.

**Documentation**

- R7. The HLD and the LoRA LLD name the tabs as the app does, and the audit tracker records S07 as done.

### Key Decisions

- **A refused or duplicate drop reopens the sheet where its result shows.** The drop handler presents the sheet only for refusals and duplicates, and the import summary renders only in Your LoRAs. The spec's rule would send a drop with no fitting installed LoRA to Recommended and hide the message. (session-settled: user-approved — chosen over following the spec's rule unchanged: that rule hides the import summary when no installed LoRA fits.) Governs R4.

### Scope Boundaries

- Not changed: `ShelfView`, `ShelfModel.pick`, the shelf license sheet and tested scale, `CivitaiBrowseView`, the NSFW opt-in and blur rules. S08 (a Civitai download goes on the stack) needs its own D34 decision and stays blocked.
- Changed beyond S07's listed steps: the sheet's drop target. S07 says a drop on the sheet "still imports as today", which held only because the sheet always opened on Your LoRAs. With Recommended opening first, U2 moves the sheet's drop handler to its root and switches to Your LoRAs after a drop, so the behavior survives the tab change.
- Not changed: the Image menu item "LoRA Library…" (S05). With Library… gone from the panel, that item is the only way to open the sheet when the selected model takes no LoRAs, because Add LoRA… then does not show (`loraAddEnabled`) while the section still does (`loraSectionVisible`).

#### Considered and not built

- Rendering the import summary anywhere other than Your LoRAs, for example in the panel. Evidence to change: a report that users miss the reason after the sheet closes.
- A permanent test of the tab rule (KTD4).

## Planning Contract

### Key Technical Decisions

- KTD1. **The opening tab is computed once, in `LoRALibraryView`'s initializer, from state that already exists.** The inputs are `model.loraLibrary` (fit), `model.shelf.rows(family:includeNSFW:)` and `model.loraImportSummary`; no new `AppModel` property. The sheet body is rebuilt on every presentation (`.sheet(isPresented:)` in `Sources/MCApp/MainWindow.swift`), and the library is loaded at launch and refreshed on every change (`refreshLoRALibrary`, called from `Sources/MCApp/AppModel+Projection.swift`), so the first frame already has the data. Always-on rows never reach `loraLibrary` (`LibraryStore.loras()` filters them, D44), so a hidden row cannot force Your LoRAs (see `docs/solutions/integration-issues/hidden-lora-rows-every-query-must-skip-them.md`).
- KTD2. **R3 and R5 ask the shelf the same question the Recommended tab asks:** `rows(family: model.loraFamily?.id, includeNSFW: model.civitai.includeNSFW)`. A family whose only SFW entry is always-on has no rows. With the opt-in off, Krea 2 Turbo has none, so its sheet opens on Civitai; FLUX.2 klein and Qwen-Image 2.1 Turbo each have an SFW entry. Checked against `catalog/models.src.json`.
- KTD3. **The R4 exception reads `model.loraImportSummary`, and the summary is scoped to one presentation.** A non-empty `refused` or `duplicates` list selects Your LoRAs before any other rule. `importLoRAs` sets the summary before `LoRADrop` presents the sheet. Today only the summary's own Dismiss button clears it, so a refusal would pin every later opening to Your LoRAs; U2 therefore clears a refusal-or-duplicate summary when the sheet disappears, and renders the summary in the empty Your LoRAs state, so the reason is on screen in the case R4 exists for. No new `AppModel` property. (session-settled: user-approved — chosen over following the spec's rule unchanged: that rule hides the import summary when no installed LoRA fits.)
- KTD4. **No permanent test for the tab rule.** It lives in a private initializer of a SwiftUI view, and a test would need a refactor the spec does not ask for. The Verification Contract exercises each outcome in the real app instead. That is the cost: a later change to the rule is caught only by the capture-kit scenarios recorded in this PR; neither `swift test` nor the automated GUI smoke (which generates an image and reuses settings, and never opens the LoRA sheet) covers it. (session-settled: user-approved — chosen over extracting the rule into a testable `AppModel` helper: it adds a seam the spec does not name.)
- KTD5. **HLD wording lands in the same PR, before the code.** AGENTS.md says never to let code diverge from a `D*` entry. D34 and D43 keep their decisions; only the tab names change, in `docs/HLD.md` and `docs/lld/loras.md`.

## Implementation Units

### U1. One entry point in the panel

- **Goal:** R1.
- **Requirements:** R1.
- **Dependencies:** none.
- **Files:** `Sources/MCApp/LoRASection.swift`.
- **Approach:**
  1. Replace the `header:` closure with plain text "LoRAs".
  2. Leave the `if model.loraAddEnabled { Button("Add LoRA…") … }` row as it is.
  3. Update the type's doc comment, which still mentions "the Library button".
- **Patterns to follow:** S07 spec, Edit steps, step 1.
- **Test expectation:** none -- a header and a removed button; the accessibility dump in the Verification Contract checks that "Library…" is gone and exactly one "Add LoRA…" remains.
- **Verification:** the panel shows "LoRAs" as plain text and a single Add LoRA… button.

### U2. Tabs, opening rule and empty-state shortcuts

- **Goal:** R2, R3, R4, R5.
- **Requirements:** R2, R3, R4, R5, R6.
- **Dependencies:** U1 is independent; both land in one PR.
- **Files:** `Sources/MCApp/LoRALibraryView.swift`.
- **Approach:**
  1. Reorder and rename `LoRASheetTab`: `shelf` "Recommended", `installed` "Your LoRAs", `browse` "Civitai". Keep all three `switch tab` cases.
  2. Replace the `@State` default with an explicit `init(model:)` that seeds `tab` from a static helper (KTD1). The helper's order is: refused or duplicate summary (KTD3), then no selected family (`model.loraFamily == nil`: Recommended and Civitai both need a model), then a fitting installed LoRA, then non-empty shelf rows (KTD2), then Civitai.
  3. In `emptyState`, add the two shortcut buttons after `importButton` (R5). `See Recommended LoRAs` shows only when the shelf query is non-empty.
  4. Narrow the segmented control to `.frame(width: 360)`.
  5. Move the `if let summary = model.loraImportSummary { importSummary(summary) }` block in `installedContent` out of the non-empty branch so it renders above `emptyState` too (KTD3). Add `.onDisappear` on the sheet body that calls `model.dismissLoRAImportSummary()` when the summary lists refused or duplicate files, so the exception applies only to the presentation the drop caused.
  6. Move the `.onDrop` that calls `LoRADrop.handle` from `installedContent` to the sheet's root `VStack`, and set `tab = .installed` in the closure before calling it, so a file dropped on Recommended or Civitai imports and its result shows (R6).
  7. Update the view's doc comment, which names "Installed" and "Browse Civitai".
- **Execution note:** `model` is declared `@Bindable`. Assign it as `self.model = model` in the initializer, and use `_model = Bindable(model)` if the compiler rejects that (S07 spec). Settle at the first build.
- **Patterns to follow:** S07 spec, Edit steps, step 2. The same shelf query is already in `Sources/MCApp/Shelf/ShelfView.swift`.
- **Test expectation:** none -- KTD4. Existing suites that touch `loraLibrary` and `loraImportSummary` (`Tests/MCAppTests/LoRAStackTests.swift`, `Tests/MCAppTests/CivitaiDownloadModelTests.swift`) must still pass; they pin model behavior, not tab labels. The new `onDisappear` only calls the existing `dismissLoRAImportSummary`.
- **Verification:** the Verification Contract's scenarios 1 to 5.

### U3. Wording and tracker

- **Goal:** R7.
- **Requirements:** R7.
- **Dependencies:** U2 (the final labels).
- **Files:** `AGENTS.md` (non-negotiable 1: "the LoRA library's Browse Civitai tab"), `docs/HLD.md` (D15, D34, D43, §4's NSFW opt-in bullet, §8.7's Browser UX lines, the Models window bullet in §10), `docs/lld/loras.md` (the "Browse tab" heading and its Browse Civitai bullet, the Shelf bullet, the "Not run" GUI bullet), `docs/design-audit/README.md` (S07 row, Progress count and date), `docs/design-audit/specs/S07-lora-sheet-entry-and-order.md` (Resolution section).
- **Approach:**
  1. HLD and LLD first (KTD5): "Browse Civitai tab" becomes "the Civitai tab", "Shelf section of the LoRA library" becomes "the Recommended tab (the shelf)", and "beside Installed" becomes "beside Your LoRAs". Change nothing else in those entries.
  2. Tracker: set the S07 row to `done (PR #n)`, bump the Progress count and date from the landed README, and add the Resolution section. It records the PR, the KTD3 deviation, the Library… consequence in Scope Boundaries, and what was and was not exercised.
  3. Leave the audit's own journey text (README section 3 and the evidence sections), which describes `633e737` by design, and `docs/plans/`.
- **Test expectation:** none -- documentation only.
- **Verification:** `grep -rniE "Browse Civitai|Shelf section|beside Installed|Browse tab|Installed detail" AGENTS.md docs/HLD.md docs/lld` finds nothing that names the tabs; the audit's journey text and `docs/plans/` are excluded by design.

## Verification Contract

Gates, from the S07 spec's acceptance list:

| Gate | Command or action |
|---|---|
| Build and tests | `swift build`, then `swift test` (about 40 s; past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`) |
| Format | `git ls-files '*.swift' \| xargs swift format lint --strict --configuration .swift-format` prints nothing |
| App build | `xcodegen generate`, then the Debug `xcodebuild` from AGENTS.md prints `** BUILD SUCCEEDED **` |
| GUI smoke | `python3 scripts/gui-smoke/run_smoke.py --models "$HOME/Library/Application Support/mlx-create/Models/Weights" --model-id Runpod/FLUX.2-klein-4B-mflux-4bit` exits 0, from an Eval cell with mlx-create quit |

Run these in the real app with the capture kit, in the order below on one throwaway home, FLUX.2 klein 4B symlinked in (`docs/solutions/developer-experience/launch-app-with-empty-library-for-first-run-testing.md`), `civitaiIncludeNSFW` off. The library starts empty; scenario 5 fills it and scenarios 6 and 7 reuse what it added:

1. **Panel.** `ax dump` shows no `AXLink` "Library…" and exactly one `AXButton` "Add LoRA…" in the left panel.
2. **Fresh library, shelf entry exists.** Press Add LoRA…: `AXRadioButton` "Recommended" has `value="1"`, and the radios sit in the order Recommended, Your LoRAs, Civitai by frame x. Then open Image ▸ LoRA Library… in a throwaway home with no model installed: "Your LoRAs" is selected, not Civitai.
3. **Empty state shortcuts.** Open Your LoRAs: **See Recommended LoRAs** switches to Recommended, and **Browse Civitai** switches to Civitai.
4. **Dropped file into an empty library.** Drop a `.txt` file on the panel: the sheet opens on Your LoRAs (R3 alone would choose Recommended) and shows the refusal reason with its Dismiss button. Close the sheet without dismissing and reopen it: it opens on Recommended, because closing cleared the summary (KTD3). Then drop the `.txt` file on the sheet itself while it shows Recommended: the sheet switches to Your LoRAs and shows the refusal. If the harness cannot drive a drag, say so in the PR rather than claim it; this is the one check KTD3 and R6 rest on.
5. **A LoRA now fits.** Add the shelf entry (Add to stack, accept the license, Download and add), close and reopen the sheet: "Your LoRAs" is selected.
6. **Civitai fallback.** Needs Krea 2 Turbo installed or symlinked, which this plan does not download. Select it with the opt-in off and open the sheet: Civitai is selected, and the empty Your LoRAs state shows no See Recommended LoRAs button. With the opt-in on, Recommended is selected. Report this scenario as not exercised if the model is unavailable.
7. **Installed but not fitting.** With the FLUX shelf LoRA from scenario 5 in the library and Krea 2 Turbo selected, the sheet opens on Civitai (opt-in off) or Recommended (opt-in on). Same availability caveat as scenario 6.
8. **Captures.** `S07_sheet_small_light.png` and `S07_panel_small_light.png` attach to the PR.

## Definition of Done

- Every gate in the table passes; scenarios 1 to 3, 5 and 8 pass; scenarios 4, 6 and 7 are passed or reported as not exercised with the reason.
- "Library…" appears nowhere in `LoRASection`, and `LoRALibraryView` has no remaining "Installed", "Shelf" or "Browse Civitai" tab labels.
- `docs/HLD.md` and `docs/lld/loras.md` use the new tab names; the audit README row, count and date, and the S07 Resolution section are updated.
- The PR body and commit message carry `Audit: S07`, and a model other than the author has reviewed the change set.
- No scratch files or throwaway homes remain, and no `mlx-serve` started for the smoke is still running (matched by the throwaway home path in argv, never by name).
