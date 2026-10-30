# LLD: GUI smoke suite

Module: `UITests/MLXCreateUITests` (UI test bundle, XcodeGen target), `scripts/gui-smoke/` (runner). Implements HLD D50. Plan: `docs/plans/2026-10-30-1108-feat-automated-gui-smoke-tests-plan.md`.

## 1. Purpose and limits

Before a UI pull request, an agent or the developer runs one local command and learns whether the real window still generates an image and lets the user work with it in the gallery. The suite drives the built app with real input events. It does not test the model layer (`swift test` does, against a stub engine) or the engine (the contract suite does, D49).

It is not part of the default `swift test` and not part of CI: it needs a real model and a free machine (D50).

## 2. Contract

1. **One command.** `scripts/gui-smoke/run_smoke.py --models DIR --model-id ORG/NAME` builds the Debug app if needed, runs the UI tests and exits non-zero when any step fails.
2. **Throwaway home.** The app runs under `CFFIXED_USER_HOME`, so the real library, models and engine state are never touched. The model is symlinked in, never copied.
3. **Refusals are "not run", never a pass.** The command refuses while mlx-create is running, when `--models`/`--model-id` do not point at a model folder with a `model_index.json`, and when Developer Mode is off.
4. **Two flows, one launch, one generation.** Generate one image, then Reuse prompt and Reuse all settings on that image, reading prompt, seed and Size back.
5. **Evidence.** Each step is a named activity with a screenshot (`lifetime = .keepAlways`), exported from the `.xcresult` to `build/gui-smoke/<timestamp>/`. A failure names the step and points at its screenshot.
6. **Clean exit.** After every run no process started by the run remains and the throwaway home is gone. Leftovers are found by the throwaway home path in their command line, never by process name.

## 3. Prerequisites

- Developer Mode on (`DevToolsSecurity -status`), enabled once by the developer with an admin password.
- A small installed model, e.g. FLUX.2 klein 4B 4-bit (about 5 GB on disk, about 8.9 GB RAM free).
- No mlx-create running.

## 4. Findings

Filled in by the U2 spike and the live runs.
