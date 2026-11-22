# GUI smoke runner

`run_smoke.py` runs the `MLXCreateUITests` UI tests against the real app and engine (HLD D50, `docs/lld/gui-smoke.md`). It is local only: it needs a real model and a free machine, so it is not part of `swift test` or CI.

## One-time setup

1. `sudo DevToolsSecurity -enable` (Developer Mode; needs an admin password). Check with `DevToolsSecurity -status`.
2. The first `xcodebuild test` shows a system authentication prompt for UI testing. Answer it at the Mac (Touch ID or password). Until then the log says "System authentication is running".
3. `brew install xcodegen` (2.46 or newer).

## Run

From an Eval Python cell, with mlx-create quit:

```python
import subprocess, sys
r = subprocess.run(
    [sys.executable, "scripts/gui-smoke/run_smoke.py",
     "--models", "<Models/Weights dir>", "--model-id", "Runpod/FLUX.2-klein-4B-mflux-4bit"],
    capture_output=True, text=True)
print(r.stdout, r.stderr)
```

`--models` is a directory holding model folders as `ORG/NAME`; the app's own `~/Library/Application Support/mlx-create/Models/Weights` works. The model is symlinked into a throwaway home, never copied.

`--agent-models DIR --agent-model-id ORG/NAME` adds the Chat flow: the agent LLM pack is symlinked in the same way, the app launches into Chat mode, and the test sends `a lighthouse on a cliff at sunset`, opens the finished tile large, sends `make it night`, then exercises the ⌘1/⌘2/⌘3 mode switcher. Without the flags only the Canvas flow runs and the command is unchanged.

Exit codes: `0` a test ran to completion and passed; `1` the run started and failed (build, timeout, test failure, or the real library or preferences changed); `2` NOT RUN, never a pass: no model configured, model folder missing or without `config.json`/`model_index.json`, mlx-create already running, Developer Mode off, or a test that skipped itself.

Evidence lands in `build/gui-smoke/<timestamp>/`: `screenshots/NN <step>.png` (a failing run adds `NN <step> FAILED.png`), `attachments/` (screen recording, hierarchy dumps), `result.xcresult` and `xcodebuild.log`. The runner prints the failing step and its last screenshot, and per-phase times. Old runs are not pruned.

The runner also restores the real `com.fearless.mlx-create` preferences the app wrote (`UserDefaults.standard` ignores the throwaway home) and fails the run if the real library under `~/Library/Application Support/mlx-create` changed. Pick a smoke model without a catalog `reference_timing`, or the app will run its D48 calibration in the throwaway home first (klein 4B has none).

The window always runs on the laptop's built-in display, whatever monitors are plugged in. macOS may open it on an external display, where XCUITest's `window.screenshot()` fails ("Failed to create screenshot"), so the runner moves it onto the built-in screen through System Events as soon as it exists; the test then waits for that. With no built-in display active (lid closed) the run is NOT RUN. The terminal that starts the runner needs Accessibility (System Settings → Privacy & Security) for the move to work.

## Self-test

`python3 scripts/gui-smoke/run_smoke.py --self-test` checks the refusals and the path-based cleanup with no engine.

## After a run

Nothing started by the run should remain. Cleanup finds leftovers by the throwaway home path in their command line (`/tmp/mlxc-smoke-*`), never by process name, so another task's `mlx-serve` is left alone. If a run was killed hard, check `pgrep -fl "mlxc-smoke"` and quit those processes by pid.
