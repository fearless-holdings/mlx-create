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

Exit codes: `0` passed, `1` a step failed, `2` NOT RUN. NOT RUN is a refusal and never a pass: no model configured, model folder missing or without `config.json`/`model_index.json`, mlx-create already running, or Developer Mode off.

Evidence lands in `build/gui-smoke/<timestamp>/` (`screenshots/NN-<step>.png`, `result.xcresult`, `xcodebuild.log`). The runner prints the failing step and its last screenshot, and per-phase times. Old runs are not pruned.

## Self-test

`python3 scripts/gui-smoke/run_smoke.py --self-test` checks the refusals and the path-based cleanup with no engine.

## After a run

Nothing started by the run should remain. Cleanup finds leftovers by the throwaway home path in their command line (`/tmp/mlxc-smoke-*`), never by process name, so another task's `mlx-serve` is left alone. If a run was killed hard, check `pgrep -fl "mlxc-smoke"` and quit those processes by pid.
