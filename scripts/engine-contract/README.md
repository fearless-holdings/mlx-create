# Engine contract runner

Runs the engine contract suite against the engine `engine.lock` pins and records the outcome there (plan U7; KTD3, KTD8; `docs/lld/engine-contract.md`). The suite proves what the app depends on from the engine; it never compares pixels across engine versions. It needs real models, so it is not part of `swift test` and not part of CI (D49). CI checks only the recorded result, with `check_lock.sh`.

## Running it

From the repo root, in an Eval Python cell (mirrors `scripts/lora-gate/README.md`):

```python
import runpy, sys

sys.argv = [
    "run_contract.py",
    "--models", "/path/to/Models/Weights",  # one folder per family in families.json plus the enhancer
    "--loras", "/path/to/Models/LoRAs",     # <family id>/*.safetensors, the layout the app writes
    "--write-lock",                         # omit for a dry run that only reports
]
try:
    runpy.run_path("scripts/engine-contract/run_contract.py", run_name="__main__")
except SystemExit as exit_status:
    print("exit", exit_status.code)
```

Optional: `--repo DIR` (default: the repo the script sits in), `--lock PATH` (default: `<repo>/engine.lock`), `--timeout SECONDS` (default 7200) for the `swift test` deadline.

The runner extracts the pinned engine with `scripts/embed-engine.sh --extract` into a fresh scratch directory, so a cold run needs the archive: a cache miss downloads it (`~/Library/Caches/mlx-create/engine/<sha256>.tar.gz`) unless `MLXC_ENGINE_OFFLINE=1`. Run it on the Mac holding the models, with the app closed and heavy applications quit: the Qwen-Image Turbo 8-bit preflight needs about 26 GB free (`docs/lld/engine.md` §5.10), and a memory refusal makes the run inconclusive. `--skip-mem-preflight` is never used.

Offline check of the pure parts (no engine, no models): `python3 scripts/engine-contract/run_contract.py --self-test` exercises the KTD3 checks and the lock rewrite on in-memory fixtures.

## Environment it sets for the suite

| Variable | Value |
|---|---|
| `MLXC_ENGINE_BIN` | the extracted `mlx-serve` of the locked version |
| `MLXC_CONTRACT_MODEL_DIR` | `--models`, read only (the throwaway `Weights` links to it) |
| `MLXC_CONTRACT_LORA_DIR` | `--loras`, read only |
| `MLXC_CONTRACT_RESULT` | `<scratch>/result.json`, a path that must not exist yet |

Every other variable is inherited, so `swift test` finds its toolchain. The scratch directory holds the extracted engine, `swift-test.log` and the result files; keep it for a failed run, the log is the only place the probe output lives.

## What a complete run records

The suite writes `result.json` only when every declared probe ran and none failed: `{engine_version, probes_expected, probes_run, failures}`. The runner then checks that `probes_run` equals `probes_expected`, `failures` is empty, the tested `engine_version` equals the lock's `version`, and `swift test` exited 0. Only then, and only with `--write-lock`, it rewrites `engine.lock`'s `contract_suite` to

```json
"contract_suite": { "result": "pass", "run_at": "2026-10-29", "version": "26.10.3", "probes": 46 }
```

Every other field keeps its exact bytes: the rewrite replaces the field's value in the file's text, so key order and line wrapping survive. Without `--write-lock` a passing run prints what it would record and leaves the lock alone.

## How an incomplete run reports

Any missing result file, probe count mismatch, non-empty `failures`, version mismatch, non-zero `swift test`, deadline hit, or leftover `mlx-serve` writes nothing to the lock and exits 1. The report names every problem, then reads `<result>.progress` — the ledger's file with `expected`, `passed`, `missing`, `failures` and, after a memory refusal, `inconclusive` — to say which probes never passed. It prints the tail of the log and the log's path. Leftovers are cleaned up first (`pkill -f swiftpm-testing-helper`, `pkill -f swift-test`, then any engine this run started under its scratch root).

A run with no result file means the suite stopped early: read `swift-test.log` for the cause.

## The CI check

`.github/workflows/engine-lock.yml` runs `sh scripts/engine-contract/check_lock.sh engine.lock` on ubuntu-latest for every pull request and for pushes to `main`. It fails unless `contract_suite.result` is `pass` and `contract_suite.version` equals the lock's top-level `version`.

It compares versions, not probe sets (§5): adding a probe does not invalidate a pass recorded earlier, because the next bump forces a complete run through this runner. It catches a forgotten re-run after a version edit, not forgery; the record's trust is the maintainer's, as for every other `engine.lock` field.
