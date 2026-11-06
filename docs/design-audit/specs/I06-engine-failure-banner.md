# I06 · Engine failure: one recovery action, the right advice, no dead Resume

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 2, minor: rare, but when it happens the screen offers two recovery actions, and one of them (Resume) fails |
| Frequency | Rare (engine crash, or macOS killing the engine under memory pressure) |
| Heuristics | H9 Help users recognize, diagnose, and recover from errors; H5 Error prevention; H1 Visibility of system status |
| User task | (e) recover from an out-of-memory error (engine killed) |
| Strategy metric | Failed generation rate |
| HLD decisions | No D* change. The engine-failure hold stays in memory only (D29) |
| Size | S |
| Depends on | none |

## Evidence

- Screenshots: `screens/07-engine-error-banner_small_light.png`, `_small_dark`, `_large_light`, `_large_dark`. The banner reads "Image engine unavailable: macOS stopped the engine because memory ran low." with a small "Restart engine" at the far right. The queue header below reads "Paused · Resume". The canvas says "Select an image in the gallery, or generate one." `screens/07a-engine-restarting-1_small_light.png` shows the restarting state. Produced by killing the engine child four times within five minutes (capture kit notes).
- Code:
  - `Sources/MCApp/EngineStatusBanner.swift`: `text` for `.failed` is `"Image engine unavailable: \(message)"`.
  - `Sources/MCEngine/EngineSupervisor.swift`: `userMessage(for:)` for `.killedBySystem` is "macOS stopped the engine because memory ran low.", which gives no advice.
  - `Sources/MCApp/QueueStripView.swift`, `QueueHeaderView`: `.paused` offers Resume whenever the queue is paused, including the in-memory engine-failure hold (`AppModel.heldByEngineFailure`). `AppModel.resumeQueue()` then refuses with "The image engine is not running. Restart the engine to resume the queue."
- Contrast is fine: banner text measures 13.21:1 (light) and 10.44:1 (dark).
- HIG, Feedback: "Use alerts to deliver critical — and ideally actionable — information."

## Target behavior

- Banner (`.failed`): text = the crash message on its own (no "Image engine unavailable:" prefix), `.callout`, `.primary`, `lineLimit(2)`. Button **Restart Engine** (title case), `.borderedProminent`, `.controlSize(.small)`.
- `.killedBySystem` message: "macOS stopped the image engine because memory ran low. Quit apps you aren't using, then restart the engine."
- `.unknown` message: "The image engine stopped unexpectedly. Restart it to continue."
- `.launchFailed` message: "The image engine couldn't start. Restart it to try again."
- While the engine has failed (`model.engineFailed`), the queue header shows `Label("Waiting for the image engine", systemImage: "pause.circle")` with **no** Resume button, whatever the pause state. After a user pause (not the engine hold), Resume shows as soon as the engine is ready again.

## Edit steps

1. `Sources/MCEngine/EngineSupervisor.swift`, `static func userMessage(for kind: CrashKind)`: change the `.killedBySystem`, `.unknown` and `.launchFailed` strings to the texts above. Leave `.outOfMemory` (it uses `OutOfMemoryFailure.message`), `.missingWeights` and `.setupFailed` as they are.
2. `Sources/MCApp/EngineStatusBanner.swift`:
   - In `text`, `.failed(let message)`: return `message`.
   - Change `.lineLimit(1)` to `.lineLimit(2)` and remove `.truncationMode(.middle)`.
   - Change the button to `Button("Restart Engine", action: onRestart).buttonStyle(.borderedProminent).controlSize(.small)`.
3. `Sources/MCApp/QueueStripView.swift`, `QueueHeaderView.body`: make the first branch of the `HStack`

   ```swift
   if model.engineFailed {
       Label("Waiting for the image engine", systemImage: "pause.circle")
   } else {
       // existing `switch model.queueHeader { … }` unchanged
   }
   ```

   Then guard both buttons: `if model.queueHeader.offersPause && !model.engineFailed` and `if model.queueHeader.offersResume && !model.engineFailed`. `engineFailed` is `internal` on `AppModel`; `QueueHeaderView` is in the same module.
4. Check `Tests/MCEngineTests/CrashClassifierTests.swift` and `EngineSupervisorTests.swift` for exact-string expectations of the three messages (`rg -n "stopped unexpectedly|memory ran low|couldn't start" Tests`). Change any you find to compare against `EngineSupervisor.userMessage(for:)` rather than a literal.
5. Format the touched files.

## Do not touch

- `RestartBudget` and backoff, the engine-failure hold (`heldByEngineFailure`, D29), and `restartEngine()`.
- The `.starting`, `.warmingModel` and `.restarting` banners.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.

With the capture kit, one model. Kill the engine four times within five minutes, by home path only: `kill -9 $(pgrep -f "mlx-serve --serve.*<home>/")`, waiting for the restart between kills.

5. `ax dump`: the banner `AXStaticText` value starts with "macOS stopped the image engine because memory ran low." and contains "Quit apps"; there is an `AXButton` "Restart Engine"; there is no `AXLink` or `AXButton` "Resume" anywhere; the queue header reads "Waiting for the image engine".
6. Press Restart Engine: within 30 s the banner disappears and the header reads "Queue empty".
7. Captures `I06_small_light.png` and `I06_small_dark.png` (failed state) are attached to the PR.

## Resolution

Done in [#44](https://github.com/fearless-holdings/mlx-create/pull/44). The change follows the edit steps, with these notes:

- `EngineSupervisor.userMessage(for:)` carries the three new messages. The `.outOfMemory`, `.missingWeights` and `.setupFailed` texts are unchanged.
- `EngineStatusBanner` shows the `.failed` message alone, at `.primary`, `lineLimit(2)`; non-failed banners keep one line and middle truncation. The failed banner offers a small `.borderedProminent` **Restart Engine**.
- `QueueHeaderView` replaces the header with `Label("Waiting for the image engine", systemImage: "pause.circle")` while `model.engineFailed`, and hides both Pause and Resume in that state. The D29 hold (`heldByEngineFailure`), `RestartBudget`, backoff and `restartEngine()` are untouched.
- `QueuePauseTests.engineRecoveryPreservesAUserPauseUntilResume` is the new regression test: a user pause survives an engine failure and recovery, the jobs stay queued, and an explicit Resume drains them.

Live acceptance used the installed `Runpod/FLUX.2-klein-4B-mflux-4bit` symlinked into a throwaway `CFFIXED_USER_HOME` at `/tmp/mlxc-i06-acceptance-20261106`; the real preferences were exported before the run and imported back after, and the real library was never opened. The home's engine child was killed four times with `SIGKILL`, each kill sent only after `/health` returned `ok` and the app's engine banner had cleared. On the fourth kill the accessibility tree showed the full value “macOS stopped the image engine because memory ran low. Quit apps you aren't using, then restart the engine.”, an `AXButton` “Restart Engine”, no `AXButton` or `AXLink` “Resume” or “Pause”, and the queue header “Waiting for the image engine”. Pressing Restart Engine cleared the banner and returned the header to “Queue empty” in 0.9 s.

Evidence: `screens/I06_small_light.png` and `screens/I06_small_dark.png` (1100×692 window; banner text 16.9:1 light and 13.1:1 dark), and the passing GUI smoke run under `build/gui-smoke/20261106-111715/`.

Exercised: `swift build`; `swift test` (296 tests, including the new pause regression); whole-tree `swift format lint --strict`; `git diff --check`; `xcodegen generate` plus Debug `xcodebuild` (`BUILD SUCCEEDED`); the normal GUI smoke (exit 0); the live four-kill acceptance above. Not exercised live: the `.unknown` and `.launchFailed` messages (the final kill classified `.killedBySystem`) and a user pause across a live engine failure (the domain regression test covers it). Cleanup matched the throwaway home path only; no process was matched by name.
