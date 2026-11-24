# LLD: GUI smoke suite

Module: `UITests/MLXCreateUITests` (UI test bundle, XcodeGen target), `scripts/gui-smoke/` (runner). Implements HLD D50. Plan: `docs/plans/2026-10-30-1108-feat-automated-gui-smoke-tests-plan.md`.

## 1. Purpose and limits

Before a UI pull request, an agent or the developer runs one local command and learns whether the real window still generates an image and lets the user work with it in the gallery. The suite drives the built app with real input events. It does not test the model layer (`swift test` does, against a stub engine) or the engine (the contract suite does, D49).

It is not part of the default `swift test` and not part of CI: it needs a real model and a free machine (D50).

## 2. Contract

1. **One command.** `scripts/gui-smoke/run_smoke.py --models DIR --model-id ORG/NAME` builds the Debug app if needed, runs the UI tests and exits non-zero when any step fails.
2. **Throwaway home.** The app runs under `CFFIXED_USER_HOME`, so the real library, models and engine state are never touched. The model is symlinked in, never copied.
3. **Refusals are "not run", never a pass.** The command refuses while mlx-create is running, when `--models`/`--model-id` do not point at a model folder holding a `config.json` or `model_index.json` (FLUX.2 klein ships only the first), and when Developer Mode is off.
4. **Two flows, one launch, one generation.** Generate one image, then Reuse prompt and Reuse all settings on that image, reading prompt, seed and Size back. With `--agent-models DIR --agent-model-id ORG/NAME` the run adds a second launch and the Chat flow: prove ⇧Return breaks a line at the caret, send a prompt, open the finished tile large, open the finished tile large and refine it there — the landing image takes the large view over — then close it, checking two tiles and no stale selection, unfurl the chat history (settled, at two thirds of the window height) and fold it back, then the ⌘1/2/3 mode switcher.
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
- **The flows launch with `-mainWindowMode canvas`.** Since D54 a fresh defaults read opens Chat mode; the launch argument sets the defaults domain, so the Canvas flows keep driving the three-panel workspace. The Chat flow passes `-mainWindowMode chat` instead — `UserDefaults.standard` is not isolated, so the mode must be named either way — plus `-MLXCAgentModelID ORG/NAME` (a linked pack has no install record) and `-MLXCNoSavedCivitaiKey YES` (a real saved key's ACL prompt would block startup). Without `--agent-model-id` the runner scopes `-only-testing:` to the Canvas test so the Chat test never appears; a skipped test would read as NOT RUN. The Chat flow launches on its own throwaway home (`TEST_RUNNER_MLXC_SMOKE_CHAT_HOME`): a Canvas image in a shared home would outrank the test's seeded history as the conversation's implicit referent. Its window is a second launch the `WindowPinner` moves too, one home at a time.
- **Launch with `-ApplePersistenceIgnoreState YES`.** macOS keeps restored-window state outside the app's home, keyed by bundle id (log: `hasPersistentStateToRestore=1`). After a session that ended with no window the next launch restores zero windows, even from a different `CFFIXED_USER_HOME`. A fresh launch with the flag opens the window.
- **The UI test runner is sandboxed.** It cannot create the home under `/tmp`, so the Python runner creates it and passes the path via `TEST_RUNNER_MLXC_SMOKE_HOME`; the test only reads it.
- **The window must be on the built-in display.** macOS opens it on a display of its choosing; a window on an external monitor made every `window.screenshot()` fail with "Failed to create screenshot. Image creation failed" (seen with a Dell on the right, window at x=2238). XCUITest cannot move a window: a title-bar `press(forDuration:thenDragTo:)`, at three offsets and two speeds, left `window.frame` unchanged. The `NSWindow Frame …` autosave key cannot be seeded because its name embeds a per-build memory address. So the Python runner's `WindowPinner` moves the app's window to the built-in display's origin plus (60, 60) through System Events (found by the home in argv plus a `.app/Contents/MacOS/` path, never by name), and `launchOnBuiltInDisplay()` in `SmokeSteps.swift` waits until `window.frame` is inside the display from `CGDisplayIsBuiltin`, failing with a message that names the cause. Proven by moving a live app window to x=2300 and letting the pinner bring it back to (60, 60). No built-in display is NOT RUN.
- **The throwaway home is honored for the library, models and engine** (`<home>/Library/Application Support/mlx-create`). The engine child outlives a killed app and carries `--model-dir <home>/…`, so cleanup by home path finds it. Match on `-MLXCSmokeHome <home>` or the home path, never on the process name.
- **`UserDefaults.standard` is not isolated.** cfprefsd keys it to the real user, so `CFFIXED_USER_HOME` does not redirect it. The app reads and writes the real `com.fearless.mlx-create` domain: the Civitai NSFW opt-in, the enhance-offer flag, the queue-pause flag, and the last-used model and current-collection ids, and AppKit writes `NSWindow Frame …` keys on every launch. The runner therefore snapshots the real domain before the run and, once the app is dead, restores every key it changed or added (AppKit's `NS…` keys are left alone). A key type it cannot write back fails the run. Flows must still not depend on those settings.
- **The real library is fingerprinted.** The runner records path, size and mtime of everything under `~/Library/Application Support/mlx-create` except `Engine/` (a stray engine logs there) before and after, using `lstat` only, and fails the run if anything differs. A user working in the real app during the run would trip it; the run refuses to start while the app is open, so that is the intended signal.
- **A skipped test is not a pass.** XCTest counts a skip as a pass and `xcodebuild` exits 0, and the UI test skips itself when its `TEST_RUNNER_` variables do not arrive. The runner reads the result bundle summary and exits 2 (NOT RUN) unless a test ran to completion and passed. A timeout, an `xcodegen` failure or a build error is exit 1 with the log, never NOT RUN.
- **A failing step is photographed.** A failed assertion stops the test before the step can screenshot itself, so a teardown block attaches the end state as `NN <step> FAILED`. Step screenshots land in `screenshots/` as `NN <step>.png`; the screen recording, XCTest's own snapshots and hierarchy dumps land in `attachments/`.
- **`.keepAlways` screenshots export from a passing run.** `xcrun xcresulttool export attachments --path X.xcresult --output-path DIR` writes the PNG (1100x690 for the default window) and a `manifest.json` mapping each file to its test and attachment name.

First live run (U4/U5, FLUX.2 klein 4B 4-bit, one launch and one generation, about 45 s end to end once built):

- **Both flows pass.** Generate: prompt, Fixed seed 424242 and the Size popup are set, Generate shows "Generation progress", and the image reaches the canvas and gallery. Restore: after changing prompt, seed policy and size, "Reuse prompt" (tile menu) restores the prompt and leaves the seed policy alone, and "Reuse all settings" restores prompt, seed policy, seed and size.
- **⌘R fires under XCUITest** (the xcresult records the activity "Restored through the ⌘R shortcut"), so the tile-menu fallback is not needed today. The test keeps it and records which path ran.
- **The "Seed policy" segments are queryable** as radio buttons named Random, Fixed and Increment (`app.radioButtons["Fixed"]`), and selection reads as value `1`. No app change was needed.
- **A product bug the suite found:** the canvas image carried its accessibility label inside `AsyncImage`'s success phase and was absent from the accessibility tree (VoiceOver would not announce the selected image). `SelectedImageView` now exposes one explicit element, label "Selected image: <prompt>" with the image trait.
- **The failure path is proven.** A deliberately wrong seed expectation failed the run with exit 1 and the message, and `--self-test` covers the refusals and cleanup.
- **Attachment names:** some XCTest auto-attachments export without an extension (`UI Snapshot …`, `Synthesized Event …`); they are property lists and are kept as exported.
- **Evidence volume:** a passing run exports about 10 screenshots plus a screen recording and one hierarchy dump per failure.
