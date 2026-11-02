---
title: Audit Quick Wins - Interrupted Size, Tab Key, Empty States - Plan
type: fix
date: 2026-11-02
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Audit Quick Wins - Interrupted Size, Tab Key, Empty States - Plan

## Goal Capsule

- **Objective:** On a first run and on every keyboard session, mlx-create no longer says something false or traps the user: a cancelled download reports what actually arrived, Tab leaves the prompt, and the empty screens describe their real state.
- **Means:** Three independent edits taken from the design-audit specs I11, I07 and I13, each proved by an automated test (KTD1, KTD3, KTD2).
- **Authority:** `docs/design-audit/specs/I11-interrupted-download-size.md`, `I07-prompt-tab-key-trap.md` and `I13-empty-state-copy.md` carry the findings, copy and acceptance checks. This plan overrides I13's `showsQueueStrip` sketch (KTD2) and replaces the specs' manual capture-kit checks with automated proof (KTD4). `docs/HLD.md` §10 wording changes in step with I13; no `D*` entry changes.
- **Execution profile:** One PR with one commit per unit. The units touch disjoint files and can land in any order.
- **Stop conditions:** Stop and report if the Tab step added to the GUI smoke does not fail on the unfixed tree (U2 step 1); then the smoke does not prove the fix and the handler is not called proven. Also stop and report if, with the handler in, Tab still does not move focus out of the prompt in the real panel (the key handler may not fire inside `TextEditor`): the fallback is an `NSViewRepresentable` text view, which KTD3 rules out and which needs a decision. Do not widen into the other audit specs.
- **Who finishes:** The implementer ships it. The GUI smoke needs a built Debug app, mlx-create quit, Developer Mode on, and the built-in display active (exit 2 is NOT RUN, never a pass).

## Product Contract

### Summary

Three small fixes from the audit's no-regret group. The interrupted-download row reports bytes written, not the file's final size. Tab and ⇧Tab move focus out of the prompt instead of typing a tab character. The first-run screens stop contradicting themselves: no "Queue empty" under a missing model, a canvas hint that matches whether a prompt is typed, and a gallery empty state that says what will happen.

### Problem Frame

V03 and V04 from the same group already merged (PRs #21 and #23); I06 was deferred to keep the batch fully test-verifiable. These three remain.

The download partials are written by ranged parts at offsets, so each partial file is sparse: its logical size is the final size and its allocated size is what has arrived. `InstallStaging.directorySize` sums logical sizes, so a download cancelled at 438 MB reads "Interrupted at 2,03 GB of 4,62 GB" and the user expects a resume far shorter than it is.

The prompt is a SwiftUI `TextEditor` with no key handling, so Tab inserts a tab character and focus never leaves it. That is a keyboard trap for keyboard and VoiceOver users, and the tab characters reach the engine in the prompt.

On the first screens, `MainWindow` shows the queue strip whenever the canvas is not in its empty-hint state, which includes "no models installed". The canvas hint tells the user to type a prompt they may already have typed, and the gallery says only "No images yet".

### Requirements

**Downloads**

- R1. An interrupted install reports the bytes actually written to its staging folder, never more than the files' logical sizes.

**Keyboard**

- R2. In the prompt, Tab moves focus to the next key view and ⇧Tab to the previous one, and neither inserts a character.
- R3. ⌥Tab still inserts a literal tab. Return still inserts a newline and ⌘↩ still generates.

**Empty states**

- R4. The queue strip is hidden when the canvas shows no models, only unavailable models, or the empty hint, unless calibration is running or the queue holds any job, whatever its status (KTD2).
- R5. The empty-hint canvas reads "Describe an image on the left, then press ⌘↩" when the prompt is empty and "Press ⌘↩ to make your first image" when it is not.
- R6. The gallery's empty state reads "Your images will appear here".

**Unchanged**

- R7. The smoke contract holds (`docs/design-audit/README.md` §13): no control name the UI tests find changes.

### Scope Boundaries

- Considered and not built: ⇧Tab and ⌥Tab as automated gates. The smoke proves Tab only; ⇧Tab and ⌥Tab rest on the spec's scratch-app check and are named as not automated in the PR description. Evidence that would change the call: a regression in either path.
- Considered and not built: the manual capture-kit checks (`ax dump`, `ax setvalue`) from the three specs, and the optional live 30-second download check in I11, which pulls real weights and needs asking first (KTD4). The sparse-file unit test covers the same defect.
- Considered and not built: a test that pins the gallery's empty-state wording (R6), which is one unbranched literal. The canvas hint's branch (R5) is tested through `AppModel` (U3).
- I06 (engine banner), the first-run path (S01, I01, I10, I12), window structure (S02 to S05) and the V-series are separate work.

## Planning Contract

### Key Technical Decisions

- KTD1. **Count allocated bytes, capped at logical size.** `totalFileAllocatedSize` is what a sparse partial really holds; the cap stops block rounding from reporting more than a file contains, so a fully written file still reads its logical size. `directorySize` goes from `private` to internal so the test can call it. Governs R1.
- KTD2. **Hide the strip only when it has nothing to show.** I13's sketch returns false for every non-`.content` mode, which would also hide queued, paused and failed jobs for a user whose models are gone or unusable (the queue persists across launches, D29). The rule is: `queueHeader == .calibrating` (the signal `MainWindow` reads today), or `.content`, or `!queueJobs.isEmpty` (any status: running, queued, paused, failed, cancelled; not a status filter). Hidden in `.noModels`, `.onlyUnavailable` and `.emptyHint` with an empty queue, which is every state I13 names. It lives next to `canvasMode` in `AppModel.swift`. Governs R4.
- KTD3. **Handle Tab with `onKeyPress` and the key window's key-view loop.** The spec's handler was tested in a scratch SwiftUI app on macOS 27.2: it lists `.tab` and U+0019 (⇧Tab arrives as the back-tab character), ignores ⌥, and calls `selectNextKeyView` or `selectPreviousKeyView`. No `NSViewRepresentable` text view is introduced. Governs R2, R3.
- KTD4. **Automated proof for every unit.** I11 gets a unit test, I13 gets `AppModelTests` cases, I07 gets a step in the GUI smoke that fails on the unfixed prompt. The specs' manual capture-kit checks are not required, so each unit also rewrites its spec's acceptance section to name the automated gate. (session-settled: user-directed — chosen over keeping the specs' manual checks: "Keep the batch fully test-verifiable".)

### Assumptions

- The temp directory used by Swift Testing is on APFS, so a truncated file is sparse. If a runner's temp volume is not sparse, the I11 test would read the logical size and fail; the implementer then points the test at a directory under the volume APFS hosts, not weakens it.
- After Tab leaves the prompt, the later smoke steps still work: `setPrompt` clicks the prompt before typing, and Generate is a button or the window-wide ⌘↩. The implementer confirms this on the first smoke run.

## Implementation Units

### U1. Interrupted downloads report real bytes (I11)

- **Goal:** `StagedInstall.bytesOnDisk`, and so "Interrupted at X of Y", counts bytes written rather than the sparse file's logical size.
- **Requirements:** R1
- **Dependencies:** none
- **Files:**
  - `Sources/MCModels/InstallStaging.swift` (modify: `directorySize`)
  - `Tests/MCModelsTests/InstallStagingSizeTests.swift` (create)
  - `docs/design-audit/specs/I11-interrupted-download-size.md` (modify: acceptance section)
- **Approach:**
  1. Make `directorySize` internal and sum `min(logical, allocated)` per regular file, using `.fileSizeKey` and `.totalFileAllocatedSizeKey`, falling back to the logical size when allocation is unavailable (KTD1).
  2. Leave `ModelDownloader`, the `.parts` sidecars, resume logic and the `InstallRow` sentence untouched.
  3. In the I11 spec, replace the manual capture-kit and optional live-download acceptance items with the sparse-file test as the gate.
- **Patterns to follow:** `Tests/MCModelsTests/ModelInstallerTests.swift` for Swift Testing style and `@testable import MCModels`.
- **Test scenarios:**
  - A 64 MiB file truncated to size with 1 MiB written at offset 0 reports at least 1 MiB and under 8 MiB. This fails on the current logical-size sum (64 MiB).
  - A small fully written file (a few KiB) reports exactly its logical size, not its block-rounded allocation.
  - An empty or missing directory reports 0.
- **Verification:** The sparse-file test fails against the unfixed `directorySize` and passes after; `ModelBrowserTests` and `ModelInstallerTests` still pass, since they pass `bytesOnDisk` as a literal.

### U2. Tab leaves the prompt (I07)

- **Goal:** Tab moves focus out of the prompt without typing a character; ⇧Tab and ⌥Tab follow the same handler, and ⌥Tab still types a tab.
- **Requirements:** R2, R3, R7
- **Dependencies:** none
- **Files:**
  - `Sources/MCApp/GenerationPanel.swift` (modify: `promptEditor`; add `import AppKit`)
  - `UITests/MLXCreateUITests/GenerateFlow.swift` (modify: step "Type the prompt")
  - `docs/design-audit/specs/I07-prompt-tab-key-trap.md` (modify: acceptance section)
- **Approach:**
  1. **First, before the handler:** add the smoke assertion and run the GUI smoke on the unfixed tree. After "Type the prompt", press Tab with `app.typeKey`, then ⌘A and ⌫ with `app.typeKey` (not `promptField.typeText`, which clicks the field first), and assert the Prompt value still equals the typed prompt. If Tab left a tab in the prompt or never moved focus, ⌘A and ⌫ empty the prompt and the step fails. If focus moved, ⌘A and ⌫ act on the next control, which is empty or a picker at the default settings, and the prompt is untouched. That is the only way the assertion tells "focus moved" from "key swallowed" (a handler that consumes Tab but finds no next view), because XCUITest has no focus property on macOS (`hasFocus` is not available there). On the unfixed tree the step must fail; if it passes, stop (Goal Capsule).
  2. Add the key handler to `promptEditor` after `.accessibilityLabel("Prompt")` as the spec's step 2 gives it (KTD3). Keep the placeholder overlay, the label and the frame logic as they are.
  3. In the I07 spec, replace the manual capture-kit acceptance items with the smoke step as the gate for Tab, and mark ⇧Tab and ⌥Tab as checked only by the spec's scratch-app run.
- **Execution note:** Test-first: the smoke step is the failing proof that precedes the handler. If the step fails after the handler for a reason other than the handler (for example the next control is a populated text field), fix the step's key target; never drop the ⌘A and ⌫ pair.
- **Test scenarios:**
  - "Type the prompt", then Tab, ⌘A, ⌫: the Prompt value still equals the typed prompt. Fails before the fix (the prompt is emptied).
  - The rest of the generate flow and the restore flow pass unchanged after focus has left the prompt (`setPrompt` re-clicks the field).
- **Verification:** GUI smoke exits 0 with the new step; it exited 1 on the unfixed tree. Return and ⌘↩ are covered by the unchanged flows; ⌥Tab and ⇧Tab are not automated.

### U3. Empty states that match the state (I13)

- **Goal:** The first screens stop contradicting themselves, without hiding jobs a user still has.
- **Requirements:** R4, R5, R6, R7
- **Dependencies:** none
- **Files:**
  - `Sources/MCApp/AppModel.swift` (modify: add `showsQueueStrip` and `emptyHintText` beside `canvasMode`)
  - `Sources/MCApp/MainWindow.swift` (modify: the strip condition)
  - `Sources/MCApp/CanvasView.swift` (modify: `.emptyHint` shows `model.emptyHintText`)
  - `Sources/MCApp/GalleryView.swift` (modify: `content` empty text and `.font(.callout)`)
  - `Sources/MCApp/ViewState.swift` (modify: the `.emptyHint` doc comment still quotes the old hint)
  - `docs/HLD.md` (modify: §10 queue-strip line)
  - `Tests/MCAppTests/AppModelTests.swift` (modify: add the tests below)
  - `docs/design-audit/specs/I13-empty-state-copy.md` (modify: Edit steps and acceptance section)
- **Approach:**
  1. Add `showsQueueStrip` (KTD2) and use it in `MainWindow` in place of the inline condition. Calibration keeps the strip even on a fresh library, as `CalibratingHeaderTests` already requires.
  2. Add `emptyHintText`: "Describe an image on the left, then press ⌘↩" when `model.prompt` is empty after trimming whitespace and newlines, otherwise "Press ⌘↩ to make your first image" (R5). `CanvasView`'s `.emptyHint` shows it, keeping `.title3`, `.secondary` and the frame.
  3. Gallery empty state: new text, `.callout`, same position (R6). The "No matches" state is unchanged.
  4. HLD §10 queue-strip bullet: replace "Hidden while the canvas shows the empty hint" with the rule in R4, so the HLD and code agree.
  5. In the I13 spec, replace the `showsQueueStrip` snippet and its step 4 with the KTD2 rule, and replace the manual capture-kit acceptance items with these tests.
- **Patterns to follow:** `zeroImageModelsShowsNoModelsAndDisablesGenerate` and `engineFailureShowsTheBannerAndKeepsQueuedJobsQueued` in `Tests/MCAppTests/AppModelTests.swift` for harness setup, `AppHarness.enqueue` and `saveImage`; `Tests/MCAppTests/CalibratingHeaderTests.swift` for the calibration case.
- **Test scenarios:** (`theStripIsHiddenUntilThereIsSomethingToShow`, `theEmptyHintFollowsThePrompt`)
  - No models, empty queue: `showsQueueStrip` is false.
  - A model installed, empty queue and gallery (`.emptyHint`): false.
  - A model installed and one saved image after `reload()` (`.content`): true.
  - No models but a queued job (enqueue directly, then `reload()`): true, so the user can still cancel it (KTD2).
  - No models but a paused job, and a failed job: true for each (the predicate is `!queueJobs.isEmpty`).
  - Calibrating with nothing queued: true; the case sets `model.queueHeader = .calibrating` directly.
  - `emptyHintText` returns the "Describe an image…" sentence for an empty prompt and for a whitespace-only prompt, and the "Press ⌘↩…" sentence once the prompt has text.
- **Verification:** Both tests pass, `CalibratingHeaderTests` and `SettingsControlsStateTests` pass unchanged, and `MainWindow` no longer holds the canvas-mode condition.

## Verification Contract

| Gate | Command or check | Applies to |
|---|---|---|
| Build | `swift build` exits 0 | U1, U2, U3 |
| Tests | `swift test` exits 0 (about 40 s; past 2 minutes it is hung: `pkill -f swiftpm-testing-helper; pkill -f swift-test`, then bisect with `--filter`) | U1, U3 |
| Lint | `git ls-files '*.swift' \| xargs swift format lint --strict --configuration .swift-format` prints nothing | U1, U2, U3 |
| App build | `xcodegen generate`, then `xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **` | U2, U3 |
| Baseline | GUI smoke on the unfixed tree with the Tab, ⌘A, ⌫ step added fails (the prompt is emptied) | U2 |
| GUI smoke | `python3 scripts/gui-smoke/run_smoke.py --models DIR --model-id ORG/NAME` exits 0, run from an Eval Python cell with mlx-create quit | U2, U3 |

## Definition of Done

- U1, U2 and U3 complete and every gate above passes. The sparse-file test fails against the unfixed `directorySize`, and the smoke Tab step failed before the handler was added.
- `docs/HLD.md` §10 and the `CanvasMode.emptyHint` comment in `Sources/MCApp/ViewState.swift` match the shipped rule.
- Each spec (I07, I11, I13) under `docs/design-audit/specs/` was updated in its own unit's commit and matches what shipped: I13's Edit steps give the KTD2 rule, and the acceptance sections name the automated gate instead of the capture-kit checks.
- The PR description names what no gate asserts: ⇧Tab and ⌥Tab, and the gallery's empty-state string (R6).
- No stray `mlx-serve` or `mlx-create` process is left running, the real preferences are untouched, and no throwaway test file or scaffold remains in the diff.

## Sources

- `docs/design-audit/specs/I11-interrupted-download-size.md`, `I07-prompt-tab-key-trap.md`, `I13-empty-state-copy.md`; `docs/design-audit/README.md` §13 (smoke contract).
- `Sources/MCModels/InstallStaging.swift` (`directorySize`, `interrupted`), `Sources/MCApp/Models/InstallRow.swift` (the "Interrupted at" row).
- `Sources/MCApp/GenerationPanel.swift` (`promptEditor`), `UITests/MLXCreateUITests/GenerateFlow.swift` (`setPrompt`, "Type the prompt").
- `Sources/MCApp/AppModel.swift` (`canvasMode`, `hasQueueOrGallery`), `Sources/MCApp/MainWindow.swift`, `Sources/MCApp/CanvasView.swift`, `Sources/MCApp/GalleryView.swift`, `docs/HLD.md` §10.
- `Tests/MCAppTests/CalibratingHeaderTests.swift` (fresh-library strip while calibrating), `AGENTS.md` Commands (gates, GUI smoke, cleanup rules).
