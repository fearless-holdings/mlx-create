# Agent gate

Provisional agent-model check (plan U1, HLD D58): can this vision LLM plan, see and write without refusing? It launches the pinned mlx-serve exactly as the app does (`127.0.0.1`, a per-launch key through `--api-key-env` with `--api-key-strict`, a private `HOME`, weights symlinked as `.mlx-serve/models`, `MLX_SERVE_QWEN_IMAGE_LOW_MEMORY=1`) and runs the phases below against one candidate. It records raw replies, timings and a mechanical validity check; it never judges refusals or softening — a reader does that from the results file. Method, pass rule and the runs' verdicts: `docs/lld/agent.md` §1.

## Running it

From the repo root, in an Eval Python cell (mirrors `docs/lld/agent.md` §1.6):

```python
import os, runpy, sys

sys.argv = [
    "check_provisional.py",
    "--engine", os.environ["MLXC_ENGINE_BIN"],   # the extracted pinned mlx-serve binary
    "--weights", "/path/to/weights",             # ORG/NAME folders: the candidate plus the image models
    "--model-id", "ORG/NAME",                    # the candidate folder under --weights
    "--scratch", "/tmp/agent-gate/run",          # images, engine HOME and log; must be outside the repo
    "--out", "scripts/agent-gate/results/<name>.json",
]
try:
    runpy.run_path("scripts/agent-gate/check_provisional.py", run_name="__main__")
except SystemExit as exit_status:
    print("exit", exit_status.code)
```

Verify the engine tarball's sha256 against `engine.lock` before extracting it; the script trusts the binary it is given. Each candidate's weight files are hashed against the Hugging Face LFS SHA-256 before use. Free memory first, as for the other gates.

`--phases` defaults to `load,sight,review,plans,explicit_text,explicit_sight`; add `swap` for the residency timing. `--max-resident-models` defaults to 3; pass 1 with `swap` to reproduce the below-24 GiB residency. `--turns` defaults to the bundled `turns.json`; `turns-explicit-followup.json` is the follow-up set for `explicit_sight`. `--text-only` runs `plans` without the referent images, for a pack whose vision tower fails.

## Phases

| Phase | What it does |
|---|---|
| `load` | cold load seconds and the engine's preflight line (the catalog's `ram_gb`) |
| `sight` | three images with a planted feature; the model answers each from the image |
| `review` | the after-image check on matching and planted-miss pairs, reply `{match, issue}` |
| `plans` | 12 scripted turns, each with the JSON schema and without, streamed; a turn is valid when the reply parses and every value is one the context offered |
| `explicit_text` | 10 explicit requests; the written prompt is recorded with the terms it must keep |
| `explicit_sight` | 4 explicit app-made images; the model reviews and describes each |
| `swap` | with `--max-resident-models 1`: image model resident, then the LLM swap around one plan |

The turns, the prompts and the pass rule are written before any candidate runs. Once a set has been seen, any tuning of the agent's instructions is judged on fresh turns (`docs/lld/agent.md` §1.5).

## Output

`--out` writes one results JSON: the sampling parameters, the system prompt, raw replies, timings and the mechanical validity verdicts per phase. Completed runs live in `scripts/agent-gate/results/`. Images stay in the scratch directory under `<scratch>/images/` and are reused by name between runs, so every run judges the same picture; engine state goes to `<scratch>/run/`. Only text goes to `--out`.
