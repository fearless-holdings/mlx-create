# LLD: GUI smoke suite

Module: `UITests/MLXCreateUITests` (UI test bundle, XcodeGen target), `scripts/gui-smoke/` (runner). Implements HLD D50. Plan: `docs/plans/2026-10-30-1108-feat-automated-gui-smoke-tests-plan.md`.

## 1. Purpose and limits

Before a UI pull request, an agent or the developer runs one local command and learns whether the real window still generates an image and lets the user work with it in the gallery. The suite drives the built app with real input events. It does not test the model layer (`swift test` does, against a stub engine) or the engine (the contract suite does, D49).

It is not part of the default `swift test` and not part of CI: it needs a real model and a free machine (D50).

## 2. Contract

1. **One command.** `scripts/gui-smoke/run_smoke.py --models DIR --model-id ORG/NAME` builds the Debug app if needed, runs the UI tests and exits non-zero when any step fails.
2. **Throwaway home.** The app runs under `CFFIXED_USER_HOME`, so the real library, models and engine state are never touched. The model is symlinked in, never copied.
3. **Refusals are "not run", never a pass.** The command refuses while mlx-create is running, when `--models`/`--model-id` do not point at a model folder holding a `config.json` or `model_index.json` (FLUX.2 klein ships only the first), and when Developer Mode is off.
4. **Two flows, one launch, one generation.** Generate one image, then Reuse prompt and Reuse all settings on that image, reading prompt, seed and Size back.
5. **Evidence.** Each step is a named activity with a screenshot (`lifetime = .keepAlways`), exported from the `.xcresult` to `build/gui-smoke/<timestamp>/`. A failure names the step and points at its screenshot.
6. **Clean exit.** After every run no process started by the run remains and the throwaway home is gone. Leftovers are found by the throwaway home path in their command line, never by process name.

## 3. Prerequisites

- Developer Mode on (`DevToolsSecurity -status`), enabled once by the developer with an admin password.
- A one-time system authentication prompt the first time `xcodebuild test` starts the UI test runner ("System authentication is running" in the log until it is answered). It needs someone at the Mac.
- A small installed model, e.g. FLUX.2 klein 4B 4-bit (about 5 GB on disk, about 8.9 GB RAM free).
- No mlx-create running.

## 4. Findings

Spike results (U2, 2026-10-30, Xcode 27.1, macOS 26.2+):

- **The runner can drive the app from the agent shell.** With Developer Mode on and the one-time authentication prompt answered, `xcodebuild test` launches the ad-hoc signed Debug app and `XCUIApplication` reads its accessibility tree. No separate Accessibility grant was needed.
- **Never pass the throwaway home as a bare positional launch argument.** AppKit treats it as a file to open, the app has no document handling, and the `WindowGroup` opens no window (XCUITest sees the menu bar only). The marker is a key/value pair, `-MLXCSmokeHome <home>`: it stays visible in `ps` for path-based cleanup and the window opens. This corrects KTD3 in the plan.
- **Launch with `-ApplePersistenceIgnoreState YES`.** macOS keeps restored-window state outside the app's home, keyed by bundle id (log: `hasPersistentStateToRestore=1`). After a session that ended with no window the next launch restores zero windows, even from a different `CFFIXED_USER_HOME`. A fresh launch with the flag opens the window.
- **The UI test runner is sandboxed.** It cannot create the home under `/tmp`, so the Python runner creates it and passes the path via `TEST_RUNNER_MLXC_SMOKE_HOME`; the test only reads it.
- **The throwaway home is honored for the library, models and engine** (`<home>/Library/Application Support/mlx-create`). The engine child outlives a killed app and carries `--model-dir <home>/…`, so cleanup by home path finds it. Match on `-MLXCSmokeHome <home>` or the home path, never on the process name.
- **`UserDefaults.standard` is not isolated.** cfprefsd keys it to the real user, so `CFFIXED_USER_HOME` does not redirect it. The app reads the Civitai NSFW opt-in and the enhance-offer flag from the real `com.fearless.mlx-create` domain, and AppKit writes `NSWindow Frame …` keys into it on every launch. Flows must not depend on those two settings, and the "defaults unchanged" check from the plan cannot hold; the real domain only gains window-frame keys.
- **`.keepAlways` screenshots export from a passing run.** `xcrun xcresulttool export attachments --path X.xcresult --output-path DIR` writes the PNG (1100x690 for the default window) and a `manifest.json` mapping each file to its test and attachment name.

First live run (U4/U5, FLUX.2 klein 4B 4-bit, one launch and one generation, about 45 s end to end once built):

- **Both flows pass.** Generate: prompt, Fixed seed 424242 and the Size popup are set, Generate shows "Generation progress", and the image reaches the canvas and gallery. Restore: after changing prompt, seed policy and size, "Reuse prompt" (tile menu) restores the prompt and leaves the seed policy alone, and "Reuse all settings" restores prompt, seed policy, seed and size.
- **⌘R fires under XCUITest** (the xcresult records the activity "Restored through the ⌘R shortcut"), so the tile-menu fallback is not needed today. The test keeps it and records which path ran.
- **The "Seed policy" segments are queryable** as radio buttons named Random, Fixed and Increment (`app.radioButtons["Fixed"]`), and selection reads as value `1`. No app change was needed.
- **A product bug the suite found:** the canvas image carried its accessibility label inside `AsyncImage`'s success phase and was absent from the accessibility tree (VoiceOver would not announce the selected image). `SelectedImageView` now exposes one explicit element, label "Selected image: <prompt>" with the image trait.
- **The failure path is proven.** A deliberately wrong seed expectation failed the run with exit 1 and the message, and `--self-test` covers the refusals and cleanup.
- **Attachment names:** some XCTest auto-attachments export without an extension (`UI Snapshot …`, `Synthesized Event …`); they are property lists and are kept as exported.
- **Evidence volume:** a passing run exports about 10 screenshots plus a screen recording and one hierarchy dump per failure.
