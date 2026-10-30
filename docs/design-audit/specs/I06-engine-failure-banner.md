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
