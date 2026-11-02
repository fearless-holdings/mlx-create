---
title: "feat: first-run path (audit S01, I10, I12, I01)"
type: feat
date: 2026-11-02
execution: code
---

# First-run path: S01, I10, I12, I01

## Summary

Ship the design audit's first-run group (`docs/design-audit/README.md` section 3, item 2). It is the shortest path to moving *time to first kept image* (`STRATEGY.md`), and the only severity-4 group that needs no HLD decision. Each spec in `docs/design-audit/specs/` carries exact edit steps and acceptance checks; the units below point at them and add what the implementer must honor.

Today a new user sees three equal grey buttons, a licence checkbox, a disabled Generate with no reason, and a download that vanishes from the main window once the browser closes. After this batch: one prominent Download button, one Accept and Download action, a line saying why Generate is disabled, and progress with time left on the canvas. Task (a) goes from 8 clicks / 3 decisions / 4 to learn to roughly 6 / 2 / 0 once the rest of the audit lands.

## Decisions

- **I10 drops the licence checkbox** (recommended default). D20 and D26 still hold: the licence is shown and accepted before the download starts, and the acceptance record (licence id, version, time) is unchanged. The spec's caveat applies: if the release-prerequisite legal read (D26, D31) wants a separate checkbox, keep only I10 steps 3 and 4. I10 is its own commit so it can be reverted alone.
- No `D*` entry changes. No HLD edit is needed.

## Scope boundaries

- Not in scope: S02-S09, I02-I09, V01-V06, and I06 (deferred). Do not touch `CanvasView`, `CanvasMode`, `LicenseSheet`'s notices, `ModelBrowserModel.beginInstall`, or the licence-before-download order.
- Each spec's own "Do not touch" list stands.

## Implementation units

Sequence: S01 first (I01 builds on its card). I10, I12 and I01's estimator are independent of S01 and of each other.

### U1. S01: one primary action on the empty canvas (size S)

- Spec: `docs/design-audit/specs/S01-first-run-single-primary-action.md`
- Files: `Sources/MCApp/EmptyModelsView.swift`
- Tests: none permanent (D50 keeps the first-launch state out of the smoke suite). Acceptance is the spec's: build, lint, an empty-home launch with `ax dump` showing exactly one `Download…` button and one `Choose a Different Model…`, light and dark screenshots, and Return opening the licence sheet.

### U2. I10: one "Accept and Download" on all three licence sheets (size S)

- Spec: `docs/design-audit/specs/I10-license-sheet-single-action.md`
- Files: `Sources/MCApp/Models/LicenseSheet.swift`, `Sources/MCApp/Shelf/ShelfView.swift`, `Sources/MCApp/Civitai/CivitaiBrowseView.swift`, plus any tests or smoke steps that tick the checkbox (GUI smoke in `Tests`/`scripts/gui-smoke`).
- Tests: update tests that drive the checkbox. Keep or add a test that acceptance is recorded (licence id, version, time) before the download starts.

### U3. I12: Generate says why it is disabled (size S)

- Spec: `docs/design-audit/specs/I12-generate-disabled-reason.md`
- Files: `Sources/MCApp/AppModel.swift` (`generateBlockReason`), `Sources/MCApp/GenerationPanel.swift`
- Tests: a permanent test for the reason precedence (download running → no model → no selectable model → engine failed → empty prompt). Behaviour, not wording.

### U4. I01: progress and time left stay visible (size M)

- Spec: `docs/design-audit/specs/I01-install-progress-visible.md`
- Depends on: U1
- Files: new `Sources/MCApp/Models/InstallRateEstimator.swift`, `Sources/MCApp/Models/InstallRow.swift`, `Sources/MCApp/EmptyModelsView.swift`, the model chip popover, and `Sources/MCApp/Models/ModelBrowserModel.swift` if the spec requires it.
- Tests: a permanent test for the estimator (nothing until 5 s of samples exist, wording buckets at 60 s and 60 min, silent outside the `.downloading` phase).

## Verification

- `swift test`, `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format`, and the `xcodegen` + `xcodebuild` build.
- GUI smoke (`scripts/gui-smoke/run_smoke.py`) after U2, because the licence sheet is on the smoke path. U1, U3 and U4 need a hand-driven empty-home run with `docs/design-audit/capture-kit.md`.
- Per the audit README convention: update each finding's Status row, bump the Progress count and date, add a Resolution section to each spec, and put `Audit: <ID>` in each commit message.
