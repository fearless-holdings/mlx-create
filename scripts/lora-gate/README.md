# LoRA gate

Pre-screen for the curated LoRA shelf and always-on LoRAs (plan `docs/plans/2026-10-22-1149-feat-curated-lora-supply-plan.md` U2; HLD D43–D47; KTD8). It answers one question per candidate: does this file fit a family, load in the pinned engine, reproduce, and stay inert at strength 0? It never judges quality, role effect or refusal behaviour — that is the author's call at the U3 decision points (R16).

## Running it

From the repo root, in an Eval Python cell (mirrors `docs/lld/enhancer.md`):

```python
import os, runpy, sys

sys.argv = [
    "run_gate.py",
    "--engine", os.environ["MLXC_ENGINE_BIN"],   # the pinned mlx-serve binary
    "--weights", "/path/to/Models/Weights",      # ORG/NAME folders, read only
    "--model-id", "ddalcu/Krea-2-Turbo",         # an installed image model; klein 4B is the small default
    "--scratch", "/tmp/lora-gate/run",           # images, engine HOME and log; must be outside the repo
    "--local-dir", "/path/to/a/folder/of/loras", # or --candidates list.json
    "--png-dir", "/path/to/invokeai/images",     # optional, usage counts only
    "--size", "512",
    "--steps", "4",
]
try:
    runpy.run_path("scripts/lora-gate/run_gate.py", run_name="__main__")
except SystemExit as exit_status:
    print("exit", exit_status.code)
```

`--mc-catalog` defaults to `swift run mc-catalog` in this repo; build once to skip the compile. `--size`, `--steps`, `--seed`, `--prompt-id`, `--family` and `--limit` are optional, and `--seed` overrides the prompt set's fixed seed.

Free memory first: the engine's preflight rejects a request when the model does not fit, and `--skip-mem-preflight` is never used (`docs/lld/engine.md` §5.9). A 512×512 image on klein 4B needs about 5 GB.

## Inputs

**Candidate list** (`--candidates`), each entry naming a local file that was already obtained by other means plus whatever public identity identifies it:

```json
{
  "candidates": [
    {"source": "civitai", "model_id": 123, "version_id": 456, "path": "/scratch/loras/a.safetensors", "family": "krea-2-turbo"},
    {"source": "huggingface", "repo": "example-org/example-lora", "file": "weights/x.safetensors", "path": "/scratch/loras/b.safetensors"},
    {"source": "local", "path": "/scratch/loras/c.safetensors", "name": "Name used in typical prompts"}
  ]
}
```

`model_id`/`version_id` and `repo`/`file` only decide the verdict id; a file with neither gets a SHA-256 prefix id. The list itself is a scratch input — keep it outside the repo when it names local paths.

**Local directory** (`--local-dir`) reads every `*.safetensors` in place and, next to each file, an optional `<stem>.cm-info.json` whose `modelId`, `modelVersionId` or `versionId`, and `modelName` supply the Civitai identity.

**InvokeAI PNGs** (`--png-dir`) are read for one thing: the `invokeai_metadata` tEXt chunk's `loras[].model.name`, counted per name. The name and the count stay harness-internal; the verdict carries the number only (R23).

## Checks

| Check | Passes when | Fails when |
|---|---|---|
| `header_fit` | `mc-catalog lora classify` reports `matched` | `unmatched` or `ambiguous`, with its reason |
| `engine_load` | a generation with the LoRA at scale 1.0 returns an image | the engine's 400 names `no modules matching`, or any other engine error |
| `reproducible` | a second generation at the same seed is byte-identical | the bytes differ |
| `strength_zero` | scale 0 is byte-identical to the no-LoRA baseline | it differs |

Fingerprint rules are never copied into Python: `mc-catalog lora classify FILE [--family ID]` prints one JSON object from `classifyLoRA` and the bundled `families.json`, reading only the safetensors header.

## Output

One verdict JSON per candidate in `results/`, named by its id:

```json
{
  "id": "civitai-123-456",
  "source": "civitai",
  "public": {"source": "civitai", "model_id": 123, "version_id": 456},
  "sha256": "…",
  "family": "krea-2-turbo",
  "variant": null,
  "engine": "26.10.3-pre-release.1",
  "model_id": "ddalcu/Krea-2-Turbo",
  "prompt_id": "o01",
  "size": 512,
  "steps": 4,
  "seed": 7,
  "checks": {"header_fit": {"ok": true, "result": "matched", "reason": "matches the krea-2-turbo fingerprint"}},
  "verdict": "pass",
  "reason": "all four checks passed",
  "usage_count": 0
}
```

Every string is passed through `scrub`, which turns any absolute path into its last component, so a verdict carries no local path and no personal file name. Images go to the scratch directory as `<id>-lora.png`, `<id>-repeat.png` and `<id>-scale0.png`, plus one `baseline-oNN.png` per run.

`verdict` is `pass` or `reject`; `reason` names the first failing check. The engine tag is recorded because vouch results are pinned to the engine they were tested on and the gate re-runs before an engine bump is pinned (R17). `usage_count` is harness-internal evidence for R16 and never reaches the catalog (R22, R23).

## Not in this harness

- Human judging, contact sheets and shelf entries. U3 prepares that evidence and the author records the decision.
- Downloads. Candidates are files obtained beforehand; the app's own download path is a separate unit (U5).
- The R12 before/after comparison. `prompts/refusal-prone.json` is a placeholder that stays empty until the author approves the real set at U3 decision point 1.

## Self-check

`python3 scripts/lora-gate/run_gate.py --self-check` runs the offline checks on `scrub` and the id rules. It starts no engine and reads no files.
