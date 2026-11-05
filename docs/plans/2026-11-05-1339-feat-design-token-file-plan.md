---
title: "One Design-Token File for Spacing, Radii, Type and Colour - Plan"
type: feat
date: 2026-11-05
execution: code
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
---

# One Design-Token File for Spacing, Radii, Type and Colour - Plan

## Goal Capsule

- **Objective:** The app's spacing, corner radii, type and colour come from one place, so the sheets, badges and cards that V02, V05 and V06 reshape cannot drift apart again.
- **Means:** Build audit finding V01 from `docs/design-audit/specs/V01-design-tokens.md`: create `Sources/MCApp/Design/MCTokens.swift` and move every view in `Sources/MCApp` and `App/` onto it (KTD1, KTD2).
- **Authority:** `docs/design-audit/specs/V01-design-tokens.md` for the token values, the mapping table, the "do not touch" list and the acceptance checks. This plan wins where it deviates (KTD2 to KTD5, and the Key Decisions below). No `docs/HLD.md` D* entry changes.
- **Execution profile:** one plain PR off `main`, not a stack (AGENTS.md reserves `gh stack` for two or more dependent PRs). It carries `Audit: V01` in the PR body and commit messages, one commit per migrated file group, and the before and after captures.
- **Stop conditions:** stop and ask if `MCTokens.swift` does not compile under the package's Swift 6 settings and the fix changes a token's type or name (KTD1), or if a snapped value clips or overflows at the 1100x692 minimum window and no token fits (R3).
- **Finishes the work:** the implementer ships the PR, then V02 is unblocked.

---

## Product Contract

### Summary

A token file defines the app's spacing steps, two corner radii, selection and field strokes, six type styles and the semantic colours. Every view takes those values from it instead of its own literals. The one-off check in V01's acceptance list prints nothing when the migration is done, and `AGENTS.md` carries the rule for later work.

### Problem Frame

The audit counted 25 distinct padding values, 16 font styles, three hand-made badge capsules and sheets that differ in title style, inset and width. None of it is a decision; each view picked its own number. V02 (readable status text), V05 (one badge) and V06 (sheet consistency) all need a shared vocabulary to build on, and without one they would add a fourth way of doing each thing. Every spec V01 waited on has shipped, so all call sites can move now.

### Requirements

**Token file**

- R1. `Sources/MCApp/Design/MCTokens.swift` exists with V01's spacing, radius, stroke, size, type and tone tokens, and no view in `Sources/MCApp` or `App/` carries its own spacing, radius, stroke width, text style or status colour literal, except where a comment says why.
- R2. V01's closing check prints nothing: `rg -n 'spacing: [1-9]|cornerRadius: [0-9]|lineWidth: [0-9]|\.font\(\.system\(size: [0-9]|\.font\(\.caption2\)|foregroundStyle\(\.(red|orange|green)\)' Sources/MCApp --glob '!Design/MCTokens.swift'`.

**Appearance**

- R3. Odd spacings snap to the nearest token, so layouts may move. Nothing may clip, truncate that did not before, or overflow at the 1100x692 minimum window, in light or dark.
- R4. Text size and colour do not change, except the title substitutions in KTD3 (a `.title3.bold()` title moves from 15 to 17 pt, a `.callout.bold()` row title from 12 to 13 pt). Every line that is 10 pt today stays 10 pt, and text that is red, orange or green today stays that colour.
- R5. Behaviour and accessibility names do not change, so the smoke contract in `docs/design-audit/README.md` section 13 still holds.

**Rule and tracker**

- R6. `AGENTS.md` states the design-token rule, and the audit tracker, V01's spec and the later specs that depend on V01's outcome reflect that V01 is done.

### Key Decisions

- **Layout moves as a side effect are acceptable.** V01's spec caps movement at 4 pt outside other specs' scope; the user lifted that cap, and R3's no-clipping check replaces it. (session-settled: user-directed — chosen over the spec's 4 pt cap: layout shifts from snapping are acceptable.) Governs R3.
- **Status colours stay on the text for now.** The spec's mapping table sends red, orange and green text to primary text plus a coloured symbol, which is V02's rule; V01 swaps each literal for the matching tone so text keeps its colour, and V02 changes the policy. (session-settled: user-approved — chosen over doing V02's change inside V01: it would merge two reviews and break V02's own before-and-after.) Governs R2, R4.
- **Existing 10 pt lines stay 10 pt.** The mapping table moves reasons and status lines to the 12 pt supporting style, which is also V02's rule; V01 keeps them on the 10 pt metadata style. (session-settled: user-approved — chosen over upsizing in V01: it would reflow the fixed-size queue cells and chips under a PR that promises no visual change.) Governs R4.
- **Odd spacings snap by role, to the nearest token.** 1, 3, 5, 7, 10, 11 and 14 pt move to a neighbouring token as the spec's table says. (session-settled: user-approved — chosen over preserving every value with exceptions: the point is a small vocabulary.) Governs R3.
- **The only enforcement is the `AGENTS.md` rule and the one-off check.** No lint script or CI guard. (session-settled: user-approved — chosen over adding a guard now: the spec does not ask for one, and V02, V05 and V06 would have to pass it.) Governs R1.

### Scope Boundaries

- Not changed: `MCStatusText` and the status-text policy (V02), the `MCBadge` view and the badge copy changes (V05), the unified sheet titles, insets, widths and button order (V06). V01 only substitutes tokens where those surfaces already are.
- Not changed: `controlSize`, `.buttonStyle`, `.foregroundStyle(.secondary)` and `.tertiary`, `Color.clear`, fixed `.frame` sizes other than the ones the spec names, and `GalleryLayout`'s column-fitting logic and its 100 and 120 pt side limits.
- The spec's call-site appendix is stale (written at `633e737`). Re-run the spec's step-2 `rg` to find hits; do not trust its line numbers.

#### Considered and not built

- A lint script or CI step that rejects literals. Evidence to change: a view lands after V06 with a literal and no comment.
- Tokens for the 81 fixed `.frame` widths and heights, beyond the few the spec's mapping table names (KTD1). Evidence to change: V06 finds sheet widths still drifting once it assigns `MCSize.sheetNarrow` and `sheetStandard`.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **The token file is the spec's file, plus three additions.** The spec gives the complete content and says it type-checks for macOS 26.2 under Swift 6 (`docs/design-audit/README.md` section 12). Create it as written, with two comment edits and any token KTD6 adds in the unit that first needs it. First, `.mcMetadata`'s doc comment adds that V02 moves the reasons still on it (KTD3). Second, the `MCTone` policy comment ("never text") adds that V01 keeps the matching tone on text until V02 moves the colour to the symbol; U6 removes both notes. `MCBadge`'s tokens (`mcBadge`, `MCTone.cardFill`) are used by the three capsules today (KTD5); `MCTone.warning` and `.success` are used as the migration reaches them. `MCSize.sheetNarrow` and `.sheetStandard` ship unused until V06 assigns sheet widths (U2 step 5). If a `static let` of `HierarchicalShapeStyle` or `Color` fails strict concurrency, change that one token to a computed `static var` and keep its name.
- KTD2. **Mapping is the spec's table, applied by role.** Values with two targets (8 and 10 as a row gap versus an inset, 10 to 12 as an inset versus a group gap) take the one the table names for that role. Each file group is one commit, in the order of the units below.
- KTD3. **Type follows size, not meaning, until V02, except the titles the spec's table assigns.** `.caption` and `.caption2` become `.mcMetadata` wherever they stand, including on reasons and status lines. `.callout` becomes `.mcSupporting` (same 12 pt). `.headline` and `.callout.bold()` on a row title become `.mcRowTitle`, including `CollectionNameSheet`'s `.headline` title, which V06 step 1 upgrades to `.mcSheetTitle` (leave a one-line comment saying so). `.title2.bold()` and `.title3.bold()` on a sheet or empty-state title become `.mcSheetTitle`, so a `.title3.bold()` title grows from 15 to 17 pt; R4 and the Definition of Done allow this. `.body` becomes `.mcBody`, except the prompt editor, which keeps `.font(.body)` as the spec says and gets a one-line reason comment. Governs R4.
- KTD4. **Colour literals map one for one.** `.foregroundStyle(.red)`, `.orange` and `.green`, and `Color.red` and `Color.orange`, become `MCTone.critical`, `.warning` and `.success`. `Color.accentColor` becomes `MCTone.selection`; `.separatorColor`, `.controlBackgroundColor` and `.textBackgroundColor` become the matching `MCTone` entries; the `.quaternary` card fills become `MCTone.cardFill`. The white glyph on the tile menu's black 0.7 chip stays literal with a reason comment (fixed contrast over arbitrary thumbnails). `EngineStatusBanner`'s `tint` is a parameter, not a literal. Governs R4.
- KTD5. **The three hand-made badge capsules get tokens in place.** Their text becomes `.mcBadge` (semibold; `InstallRow` is bold today, the LoRA capsules regular). Paddings snap by the spec's table: `InstallRow`'s 6 and 2 pt become `MCSpacing.compact` and `.hairline`, while the 5 and 1 pt capsules in `LoRALibraryView` and `CivitaiBrowseView` become `MCSpacing.tight` and `.hairline`. V05 replaces them with `MCBadge`.
- KTD6. **Residual fonts keep a system style with a reason, or become a token.** These have no token: the monospaced variants (`.body.monospaced()`, `.caption.monospaced()`), `.title2` on the failure icon in `CanvasView`, `.body.weight(.medium)`, `.caption.weight(.semibold)`, the tile menu's `.system(size: 12, weight: .semibold)`, the bare `.title3` hint in `CanvasView` and the `.title2` failure title in `App/MLXCreateApp.swift` (both on Text), and `.caption.bold()` on the licence-notice name in `LicenseSheet` (KTD5 covers only the capsule uses). A style used in two or more places is added to `MCTokens.swift`; one used once stays literal with a one-line comment. The tile glyph must stop matching V01's closing check, so it moves to a token or to `.mcSupporting.weight(.semibold)`.
- KTD7. **`GalleryLayout.inset` and `.spacing` take `MCSpacing.group` and `.regular`.** Its `minSide` and `maxSide` limits stay AppKit constants. The values stay 12 and 8, so the layout fit does not change.
- KTD8. **V02's find command stops finding text after V01.** V02's step-2 `rg` and its acceptance check search for `foregroundStyle(.red|.orange|.green)` and `Color.red`; after V01 swaps them for `MCTone`, that search returns nothing while the text is still coloured. U6 rewrites V02's search to find `MCTone.critical`, `.warning` and `.success` on text lines.

### Sources and Research

- V01's measured inventory and mapping table: `docs/design-audit/specs/V01-design-tokens.md`. At plan time the closing `rg` hits 19 files under `Sources/MCApp`; `App/MLXCreateApp.swift` and the `GalleryLayout` constants in `GalleryCollectionView.swift` also need migration. The residual fonts are the ones in KTD6, and the distinct colour literals are the ones in KTD4.
- Boundary with V02 and V05: `docs/design-audit/specs/V02-text-contrast-and-status-colour.md` (Rules 1 and 2 own the status-text and 12 pt changes) and `docs/design-audit/specs/V05-badges-and-redundant-labels.md` (owns `MCBadge`).
- PR evidence procedure: `docs/solutions/developer-experience/attach-screenshots-to-a-pull-request-with-gh-pr-comment-attach.md`. Throwaway home for the first-launch capture: `docs/solutions/developer-experience/launch-app-with-empty-library-for-first-run-testing.md`.
- Plan shape and the one-PR convention: `docs/plans/2026-11-04-1326-feat-lora-sheet-entry-and-order-plan.md`.

### Risks

- **Snapped spacings squeeze a fixed-size or minimum-width surface.** The queue cells are 176x64, the composer panel scrolls at small heights, and the model chip and prompt-history popovers size to content. Mitigation: the captures at 1100x692, including both popovers, are the check for R3, taken before any edit and again after U5.
- **A strict-concurrency error in the token file.** Covered by KTD1's fallback.
- **swift-format rewrites the token file on write.** The harness runs `swift format` on every Swift edit (AGENTS.md); write it as the formatter would and expect a whitespace-only difference from the spec's listing.

---

## Implementation Units

### U1. Token file and baseline captures

- **Goal:** R1 (the file), R3 (the baseline it is judged against).
- **Requirements:** R1, R3.
- **Dependencies:** none.
- **Files:** `Sources/MCApp/Design/MCTokens.swift`.
- **Approach:**
  1. Before any edit, take the "before" captures on `main` (Verification Contract, captures 1 to 4), so the baseline is not the migrated app.
  2. Create the file from the spec's listing, with KTD1's comment edit.
  3. Build once to settle KTD1's concurrency question.
- **Execution note:** the baseline captures come first; once a view changes, the "before" cannot be retaken without a stash.
- **Patterns to follow:** V01 spec, "Target: the token file". Other `MCApp` subfolders (`Civitai/`, `Shelf/`, `Models/`) are picked up by SwiftPM without a manifest change.
- **Test expectation:** none -- constants only, no consumers yet; the build is the proof.
- **Verification:** `swift build` exits 0 with the file in place and unused; the baseline captures for states 1 to 6 exist in light and dark.

### U2. Sheets, banners and cards

- **Goal:** R1, R2 for the surfaces V06 and V02 will reshape next.
- **Requirements:** R1, R2, R3, R4.
- **Dependencies:** U1.
- **Files:** `Sources/MCApp/Models/LicenseSheet.swift`, `Sources/MCApp/Models/ModelBrowserView.swift`, `Sources/MCApp/EnhancerInstallSheet.swift`, `Sources/MCApp/CollectionMenu.swift`, `Sources/MCApp/Shelf/ShelfView.swift`, `Sources/MCApp/PromptHistoryPopover.swift`, `Sources/MCApp/DropRestoreBanner.swift`, `Sources/MCApp/EngineStatusBanner.swift`, `Sources/MCApp/EnhanceResultCard.swift`, `App/MLXCreateApp.swift`.
- **Approach:**
  1. In each file, run V01's step-2 `rg` and replace every hit by KTD2 to KTD6.
  2. Sheet and empty-state titles follow KTD3: `.title2.bold()` and `.title3.bold()` titles take `.mcSheetTitle`, and `CollectionNameSheet`'s `.headline` title takes `.mcRowTitle`. V06 unifies insets, widths and the remaining titles later; V01 substitutes the token that matches each inset.
  3. `ShelfView` holds two sheets' worth of views (the row and the shelf licence sheet); migrate both.
  4. `App/MLXCreateApp.swift`: `LaunchLoadingView` has no title font, so only its stack spacing takes a token. The failure view's `.title2` title stays literal with a reason comment (KTD6). Leave `Text("Opening library...")`'s `.secondary` as it is.
  5. Sheet `.frame(width:)` literals (340, 480, 500, 520) stay as they are, and `MCSize.sheetNarrow` and `.sheetStandard` stay unused; V06 assigns the two widths. Frames the spec's mapping table names for non-sheet views (the 44 pt empty-state symbol, the 64 pt Civitai thumbnail, the 24 pt tile-menu button, the 520 pt empty-state max width) take their `MCSize` token in the unit that owns that file.
- **Patterns to follow:** V01 spec, "Mapping rules for the migration".
- **Test expectation:** none -- substitution of constants with no behaviour change; the build and the captures are the proof.
- **Verification:** the step-2 `rg` on each file lists only intentional keeps, each with a reason comment; the licence sheet, enhancer sheet and collection-name sheet open in the real app without clipped text.

### U3. Gallery

- **Goal:** R1, R2 for the gallery and its AppKit layout constants.
- **Requirements:** R1, R2, R3, R4.
- **Dependencies:** U1.
- **Files:** `Sources/MCApp/GalleryView.swift`, `Sources/MCApp/GalleryCollectionView.swift`.
- **Approach:**
  1. `GalleryView`: apply KTD2 to KTD6. The tile selection ring takes `MCStroke.selection` and `MCRadius.card`; the tile menu's chip takes `MCRadius.field` (KTD4, KTD6 for its glyph).
  2. `GalleryCollectionView`: set `GalleryLayout.inset` and `.spacing` per KTD7 and leave the column-fitting code and `panelSides` and `fullWindowSides` alone.
- **Patterns to follow:** V01 spec, "Do not touch" for `GalleryLayout`.
- **Test expectation:** none -- the layout values are unchanged (12 and 8), and no test references `GalleryLayout`. The populated-gallery capture checks that the grid still fits the same columns.
- **Verification:** the gallery capture (light and dark) shows the same column count as its baseline at 1100x692; arrow-key navigation still moves a row at a time.

### U4. Model, LoRA and Civitai surfaces

- **Goal:** R1, R2 for the surfaces with the most literals.
- **Requirements:** R1, R2, R3, R4.
- **Dependencies:** U1.
- **Files:** `Sources/MCApp/Models/InstallRow.swift`, `Sources/MCApp/EmptyModelsView.swift`, `Sources/MCApp/ModelChip.swift`, `Sources/MCApp/LoRASection.swift`, `Sources/MCApp/LoRALibraryView.swift`, `Sources/MCApp/Civitai/CivitaiBrowseView.swift`.
- **Approach:**
  1. Apply KTD2 to KTD6 in each file.
  2. The three capsules (`InstallRow`'s two, `LoRALibraryRow`'s and `CivitaiResultRowView`'s) follow KTD5; the in-stack and just-added capsules in `LoRALibraryView` and the `CivitaiSourceSection` one are the same style.
  3. Card fills in `EmptyModelsView` and `LoRALibraryView`'s import summary take `MCTone.cardFill` (the `.opacity(0.5)` variant keeps its opacity).
  4. `LoRASection`'s adaptive grid spacing is `spacing: 6`, which the closing `rg` matches; it takes `MCSpacing.compact`.
- **Test expectation:** none -- substitution of constants; existing LoRA and browser suites must still pass.
- **Verification:** the model browser, LoRA sheet (each tab) and first-launch card render without clipped or wrapped badges and rows at 1100x692, and the model chip popover shows its rows intact. The U5 captures are the evidence for these states; there is no separate round after U4.

### U5. Generation panel, canvas and queue

- **Goal:** R1, R2 for the screens the user sees every session.
- **Requirements:** R1, R2, R3, R4, R5.
- **Dependencies:** U1. Do it last of the code units, so the captures judge the finished app.
- **Files:** `Sources/MCApp/GenerationPanel.swift`, `Sources/MCApp/ComposerSettings.swift`, `Sources/MCApp/CanvasView.swift`, `Sources/MCApp/QueueStripView.swift`.
- **Approach:**
  1. Apply KTD2 to KTD6. Keep `.font(.body)` on the prompt editor with a reason comment (KTD3).
  2. The drop-target rings (`CanvasView`, `GenerationPanel`) and the queue cell's selection ring take `MCStroke.selection`; the LoRA drop ring moves from 2 to 3 pt.
  3. The prompt editor's radius and outline take `MCRadius.field` and `MCStroke.hairline` (the outline is the default stroke width today, so its literal is only the radius).
  4. `QueueStripView`'s cell keeps its 176x64 frame; check it against the snapped padding before moving on.
- **Test expectation:** none -- substitution of constants. The GUI smoke covers generate, reuse prompt and reuse settings, which touch every changed file in this unit.
- **Verification:** at 1100x692 the composer panel has the same controls on screen as its baseline, the queue cell's prompt line and status line do not clip, the failure card, enhance card and canvas bar render intact, and the prompt-history popover shows its rows and filter field intact.

### U6. Rule, tracker and dependent specs

- **Goal:** R6.
- **Requirements:** R6.
- **Dependencies:** U2 to U5 (the PR number and what was exercised).
- **Files:** `AGENTS.md`, `docs/design-audit/README.md`, `docs/design-audit/specs/V01-design-tokens.md`, `docs/design-audit/specs/V02-text-contrast-and-status-colour.md`.
- **Approach:**
  1. `AGENTS.md`, Engineering conventions: add V01's rule verbatim: "**Design tokens:** views take spacing, radii, type and colour from `Sources/MCApp/Design/MCTokens.swift` (docs/design-audit/specs/V01). A literal spacing, radius, font or colour in a view needs a reason in a comment."
  2. `docs/design-audit/README.md`: V01 row to `done (PR #n)`; Progress line to 24 of 28 done, 3 open, with the date; section 3 step 7 records V01 as shipped in the `(done, [#n](…))` form the finished steps use; section 12's "remaining suggested trial" sentence updated.
  3. V01 spec: add a Resolution section with the PR, the Key Decisions' deviations (layout cap lifted, colours and 10 pt text deferred to V02), the kept literals and their reasons, and what the captures and smoke exercised.
  4. V02 spec: rewrite step 2's find command and acceptance check 6 to find `MCTone.critical`, `.warning` and `.success` on text (KTD8), and add a step that removes the `.mcMetadata` and `MCTone` comment notes (KTD1) once the reasons have moved and the colour is on the symbols.
  5. Leave the audit's evidence sections, which describe `633e737` by design, and `docs/plans/`.
- **Test expectation:** none -- documentation only.
- **Verification:** `rg 'foregroundStyle\(\.(red|orange|green)\)' docs/design-audit/specs/V02-text-contrast-and-status-colour.md` finds no search that would now return nothing; the README's count matches its Status column.

---

## Verification Contract

Gates, from V01's acceptance list:

| Gate | Command or action |
|---|---|
| Build and tests | `swift build`, then `swift test` (about 40 s; past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`) |
| Format | `git ls-files '*.swift' \| xargs swift format lint --strict --configuration .swift-format` prints nothing |
| App build | `xcodegen generate`, then the Debug `xcodebuild` from AGENTS.md prints `** BUILD SUCCEEDED **` |
| GUI smoke | `python3 scripts/gui-smoke/run_smoke.py --models "$HOME/Library/Application Support/mlx-create/Models/Weights" --model-id Runpod/FLUX.2-klein-4B-mflux-4bit` exits 0, run from an Eval cell with mlx-create quit |
| Closing check (R2) | the `rg` in R2 prints nothing |
| Kept literals (R1) | V01's step-2 `rg` over `Sources/MCApp` and `App/`, plus `Color\.accentColor` (which the spec's `rg` does not match), lists only lines with a reason comment |
| Smoke contract (R5) | the GUI smoke gate above is R5's check: it drives the names in `docs/design-audit/README.md` section 13 |

Captures, taken with the capture kit (`docs/design-audit/capture-kit.md`) at 1100x692, light and dark:

1. First launch: throwaway home with an empty library.
2. Populated gallery: throwaway home with FLUX.2 klein 4B symlinked and a few images.
3. The same home, an image selected, with the queue strip and composer visible.
4. The Models sheet and the LoRA sheet (Recommended tab) open.
5. The model chip popover open (the same home).
6. The prompt-history popover open (the same home, with at least one recent prompt).

Captures 1 to 6 are taken before U1's first view edit and again after U5. Review each "after" against its "before" for clipping, truncation that did not exist before, and wrapped badges (R3), and note any visible shift in the PR. Attach the pairs to the PR with `gh pr comment --attach`, as in `docs/solutions/developer-experience/attach-screenshots-to-a-pull-request-with-gh-pr-comment-attach.md`.

---

## Definition of Done

- Every gate passes, and the closing check prints nothing.
- Each kept literal has a reason comment, and no residual font used twice is left literal (KTD6).
- Text size and text colour are unchanged except the title substitutions in KTD3 and KTD5's badge weight; the before and after captures show no clipping or overflow at 1100x692.
- `MCTokens.swift` is the only place a token value is defined, and `AGENTS.md` carries the rule.
- The audit README, V01's Resolution section and V02's rewritten search commands are updated (U6).
- The PR body and commits carry `Audit: V01`, and the change set has had a high-level review by the GPT-6.1 Sol model agent, per the project's review rule.
- No scratch files or throwaway homes remain, and no `mlx-serve` started for the smoke is still running (matched by the throwaway home path in argv, never by name).
