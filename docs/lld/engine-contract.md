# LLD: Engine contract suite

Module: `Tests/MCEngineContractTests` (Swift Testing target), `scripts/engine-contract/` (runner), `.github/workflows/engine-lock.yml` (record check). Implements HLD §7.3 under D49. The pin, the bump procedure and `engine.lock`'s `contract_suite` field are in `docs/lld/engine.md` §3.

## 1. Purpose and limits

An engine bump merges only after this suite has run, to completion, against the exact binary being pinned. The suite proves what the app depends on from the engine. It does not test the app (queue, executor, UI have their own tests against stubs) and it does not compare pixels across engine versions.

It is not part of the default `swift test` and not part of CI: it needs real models, which no CI runner holds (D49). CI checks only the recorded result (§6).

## 2. Contract

1. **The suite goes through the app's own code.** It launches the engine with `EngineSupervisor` (so argv, environment, `HOME`, models symlink and readiness are the app's), talks to it through `EngineClient`, and resolves families through `InstalledModels` and `FamilyRegistry`. Raw HTTP is used only where the client cannot express the case: a request without the key or with a wrong key, a response header, a request body the client never builds.
2. **Models are real folders.** `MLXC_CONTRACT_MODEL_DIR` is a directory of model folders (the engine's `--model-dir` layout). The throwaway `Models/Weights` is a symlink to it, as `ReferenceTimingMeasurementTests` does, so nothing in that directory is moved or written.
3. **Coverage comes from `families.json`.** Every family in the bundled registry and the enhancer must be present, and every probe declared for a family runs once per family. A missing model makes the run incomplete, not green.
4. **A result exists only for a complete run.** Every probe id is declared in one enum (`ContractProbe`). Each probe records its id in one actor-owned ledger as it finishes. The ledger writes the result file exactly once, after every declared id has been recorded and none failed. A skipped, partial or inconclusive run writes nothing. A meta-test fails when a probe records an id outside the enum or a declared id has no probe.
5. **Assertions are structural, plus invariants inside one engine run.** Field presence, status codes, event order, PNG validity and dimensions, and byte equality between two requests on the same engine (same seed; LoRA scale 0 against no LoRA). Never a golden image from another engine version: `v26.10.3` changes stacked-LoRA rounding on Qwen-Image, so such a golden would fail on a correct change.
6. **Residency is asserted by invariant.** Upstream's eviction planner credits a victim's prefix cache (`v26.10.3`), so which model is evicted is not the app's business. The app needs: loaded count at most the limit, and the requested model loaded after a successful load.
7. **A memory refusal makes the run inconclusive.** A load that returns `out_of_memory` stops the suite with the engine's own text and the free-memory reading, and writes nothing. No retry loop, and never `--skip-mem-preflight`: a retry hides a real memory regression.
8. **Nothing outside the throwaway root changes.** No write under the real `~/.mlx-serve`, none under the app's Application Support folder, no change to a model folder, and no `mlx-serve` left running.

## 3. Prerequisites

| Input | Variable | Content |
|---|---|---|
| Engine | `MLXC_ENGINE_BIN` | The extracted `mlx-serve` of the version under test. The runner extracts it with `scripts/embed-engine.sh --extract` |
| Models | `MLXC_CONTRACT_MODEL_DIR` | One folder per family in `families.json` plus the enhancer |
| LoRAs | `MLXC_CONTRACT_LORA_DIR` | `<family id>/*.safetensors`, a layout the app already writes (`Models/LoRAs`). The suite checks each file's family with `FamilyRegistry.classifyLoRA` and never trusts a file name. Nine files for one family are needed for the cap probe, and the Krea always-on file for the always-on probe |
| Result | `MLXC_CONTRACT_RESULT` | A path the suite writes once. Set by the runner to a new file in a fresh scratch directory |

Memory: run with the app closed and other heavy apps quit. The Qwen-Image Turbo 8-bit preflight needs about 26 GB free (`docs/lld/engine.md` §5.10).

## 4. Probe catalog

`<f>` is a family id from `families.json`; a probe marked per family runs once per family and its id carries `.<f>`.

| Probe id | Requirement | Assertion | Why the app needs it |
|---|---|---|---|
| `launch.ready-and-version` | R1 | Engine reaches `.ready` with the app's argv; `mlx-serve --version` first line is `mlx-serve <engine.lock version>` | Supervisor readiness and the lock/version match the build script enforces |
| `launch.argv-has-no-key` | R5 | `ps -o command=` for the engine does not contain the key | argv is world-readable (AGENTS.md non-negotiable 4) |
| `auth.health-open` | R5 | `GET /health` without a key is 200 with `status` `ok` | Readiness poll sends no key |
| `auth.missing-key-401` | R5 | `GET /v1/models` without a key is 401 with the error envelope | `--api-key-strict` is the only thing keeping loopback callers out |
| `auth.wrong-key-401` | R5 | A wrong key is 401 | Same |
| `auth.right-key-200` | R5 | The right key is 200 | Same |
| `auth.loopback-only` | R5 | A TCP connect to the Mac's non-loopback address on the engine port is refused | Non-negotiable 4 |
| `isolation.real-home-untouched` | R10 | The whole real `~/.mlx-serve` tree is unchanged, and the engine's logs and files land under the throwaway `HOME` | Non-negotiable 5 |
| `models.lists-installed-families` | R6 | Every family's model appears in `/v1/models` with `image` capability and an architecture `InstalledModels` maps to that family, available | Family resolution drives every UI control |
| `models.rescan-sees-new-folder` | R6 | A symlink added to `Weights` after launch appears in `/v1/models` right after one rescan | Install makes a model usable without an engine restart |
| `models.load-unload` | R6 | `load-model` and `unload-model` return 200 and `loaded` follows | Queue and enhancer lease depend on it |
| `models.unload-not-resident` | R6 | Unloading a model that is not resident returns 200 | The lease unloads blindly after the engine may have evicted |
| `models.load-unknown-fails` | R6 | Loading an unknown id fails with an `EngineError` other than success | A bad id must not look like a loaded model |
| `residency.single-slot` | R6 | At the 16 GB tier (limit 1), loading the enhancer then an image model leaves at most one `loaded`, and the requested one is among them | AE4; the lease's 16 GB path |
| `residency.multi-slot` | R6 | At the larger tier, two models stay loaded | The lease leaves residents alone at 24 GiB and above |
| `image.stream-shape.<f>` | R2 | Progress events carry `step` and `total`, `step` never decreases, exactly one `complete` event, its base64 decodes to a PNG, no `preview` frame arrives | `SSELineParser` and the progress UI |
| `image.dimensions.<f>` | R2 | PNG size equals the request at the family's smallest preset | Metadata and the canvas trust the requested size |
| `image.size-clamp.<f>` | R2 | A request off `sizeGrid` renders at the clamped size the registry computes | `FamilyRegistry.normalize` mirrors the engine's clamp |
| `image.default-steps.<f>` | R2 | A request with no `steps` succeeds, and the stream's `total` equals the family's `defaultSteps` | The request omits `steps` unless the user changed it |
| `image.seed-determinism.<f>` | R2 | Two requests with one seed return identical PNG bytes; another seed returns different bytes | Drop-to-restore and seed policies |
| `image.composed-request.<f>` | R2 | A request with no `guidance_scale` and no negative prompt (what the app composes for every shipped record) is accepted and returns a PNG | The app sends neither field |
| `image.cancel-recovers.<f>` | R2 | Cancelling mid-stream ends the job, `/health` answers, and the next generation on the model completes | Cancel is closing the connection (AGENTS.md) |
| `image.missing-prompt-400` | R2 | A raw request with no prompt is 400 with the error envelope | `EngineError.badRequest` mapping |
| `lora.applies.<f>` | R3 | One LoRA at scale 1 returns a PNG that differs from the same seed without it | The LoRA stack |
| `lora.scale-zero.<f>` | R3 | Scale 0 returns bytes identical to no LoRA | Documented "strength 0 turns a LoRA off" (`docs/lld/engine.md` §5.10) |
| `lora.scale-range.<f>` | R3 | Scale -1 and 5 are accepted | The slider range |
| `lora.rejects-wrong-family.<f>` | R3 | Another family's LoRA returns 400 whose body contains `no modules matching`, mapped to `loraRejected` | The app's compatibility check treats the engine as final authority |
| `lora.cap-eight-nine` | R3 | Eight LoRAs succeed and nine return a 400 naming the cap (`max 8`), mapped to `badRequest` | `GenerationComposer.engineLoRAMax`, which the composer and executor enforce before the engine does |
| `lora.relative-path-rejected` | R3 | A relative path is rejected, an absolute path outside the model directory loads | The app always passes absolute library paths |
| `lora.always-on-plus-user` | R3 | The Krea always-on file together with a user LoRA returns a PNG | The executor's always-on append (D44) |
| `lora.no-rescan-needed` | R3 | A LoRA file placed after launch applies without a rescan | AGENTS.md: "LoRAs need no rescan" |
| `chat.stream-shape` | R4 | A real enhancer stream decodes through `ChatStreamParser`: content deltas, a `stop` finish, `[DONE]` | The enhancer |
| `chat.no-thinking-text` | R4 | With `enable_thinking: false` no reasoning text reaches the content | The enhancer shows the content |
| `chat.length-truncation` | R4 | A small `max_tokens` ends with `finish_reason` `length`, mapped to `chatOutputTruncated` | Truncated enhancements must fail visibly |
| `chat.unknown-model-behavior` | R4 | On a fresh launch with nothing loaded, a chat naming an unknown model is 503 `no_model` (mapped to `noModel`); a chat naming the registered but unloaded enhancer loads it on demand and answers; once a model is resident, a chat naming an unknown id still answers 200 (the engine falls back to the resident model and echoes the requested id) | The engine is no backstop for an uninstalled enhancer, so the app's own `enhancer.isInstalled` guard (`AppModel+Enhance`) is the only check. Measured at 26.10.3-pre-release.1; replaces the first draft, which assumed a 503 `model_not_loaded` for an unknown id |
| `chat.keyless-401` | R4, R5 | A chat request without the key is 401 | Same key rule on the chat route |
| `log.refused-load-classifies` | R7 | The engine's refusal log tail classifies as `outOfMemory` | Crash and retry policy. Synthetic fallback: see §5 |
| `log.missing-weight-classifies` | R7 | The engine's log for a multi-shard model folder with one weight file left out classifies as `missingWeights` | Same |
| `log.request-echo-ignored` | R7 | After an enhancer chat, an echoed request line (the chat route is the only one that echoes) does not change the classification of an unrelated error | Echo lines can contain any needle |

## 5. Known limits

- A mid-stream engine `error` event cannot be forced on a healthy engine, so that path stays covered by its recorded fixture (`Tests/MCEngineTests/Fixtures/Client`) only.
- `log.refused-load-classifies` uses a launch that makes a load refuse safely. If the pinned engine has no flag for that, the probe uses the recorded fixture and this row says so (§7 record).
- `ModelEntry.state` is decoded and has no consumer, so the suite does not pin it.
- The CI check compares versions, not probe sets. Probes added later do not invalidate an older `pass` until the next bump, when the runner's manifest check forces a complete run.
- The record is not signed. Its trust is the maintainer's, as for every other `engine.lock` field; the check exists to catch a forgotten re-run, not forgery.

## 6. Runner and CI

- `scripts/engine-contract/run_contract.py` (run from an Eval cell, like `scripts/lora-gate/`) extracts the engine, points `MLXC_CONTRACT_RESULT` at a new file in a fresh scratch directory and refuses to start if a file is already there, runs `swift test --no-parallel --filter MCEngineContractTests` (cross-suite exclusivity: `.serialized` orders only tests inside one suite, and two engines at once would make memory refusals the norm), and writes `contract_suite` into `engine.lock` only when the result file exists, `probes_run` equals `probes_expected`, there are no failures, and `engine_version` equals the lock's `version`.
- The result file holds `{engine_version, probes_expected, probes_run, failures}`. `engine_version` is the bare version parsed from the engine's `mlx-serve <version>` line, the same string `engine.lock` holds.
- `.github/workflows/engine-lock.yml` fails unless `contract_suite.result` is `pass` and `contract_suite.version` equals `version`. It lands together with the first recorded `pass`; merged earlier it would fail every PR while the lock says `smoke-only`.

## 7. Records

Findings from baseline and bump runs, and every contract amendment with its reason, are appended here. Nothing is loosened silently: a probe whose assumption fails on the old engine is fixed in the app, fixed in the probe, or amended here with the reason.

### 2026-10-29: baseline on 26.10.3-pre-release.1 (61 probes, pass)

Run on a 48 GiB Mac with klein 4B, Krea 2 Turbo and Qwen-Image 2.1 Turbo installed. First attempts hit memory refusals (another local job held RAM): those ended inconclusive and wrote nothing, as designed. Findings, each resolved on its own:

| Probe | What the first run showed | Resolution |
|---|---|---|
| `chat.unknown-model-behavior` (was `chat.model-not-installed`) | Assumed 503 `model_not_loaded` for an unknown id. Measured: 503 `no_model` only with nothing loaded; a registered but unloaded id loads on demand; with any model resident an unknown id answers 200 using that model and echoes the requested id | Amended (catalog row above). No app change: `AppModel+Enhance` already refuses locally when the enhancer is not installed, and the contract now says the engine will not do it |
| `lora.cap-eight-nine` | Nine LoRAs return 400 `too many 'lora_paths' (max 8)`, which the app maps to `badRequest`, not `loraRejected` | Amended: the contract is a 400 naming the cap. The app never sends nine (composer and executor stop it), so no app change |
| `log.missing-weight-classifies` | A folder with a single weight file left out is an empty model: the engine logs `NoWeightFiles` ("incomplete download") and `CrashClassifier` returns `unknown`. A multi-shard model missing one shard logs `[flux] MISSING WEIGHT: …` and classifies `missingWeights` | Probe fixed to leave out one shard of a multi-shard model. **Known gap, not fixed:** the all-weights-missing case (`NoWeightFiles`) is a 500 `model_load_failed` on a live engine, not a crash, and the installer hash-verifies every file, so it needs a hand-damaged folder |
| `log.request-echo-ignored` | Image routes log only a character count (`[image] generating …: 72 chars`), never the prompt. Only chat logs the `> "…"` echo | Probe fixed to drive the enhancer chat route |
| `models.rescan-sees-new-folder` | Probe required the added alias to be an image model, but the first folder mirrored is the enhancer | Probe fixed: any listed id counts |
| `lora.*` per family | At the single-slot tier a LoRA probe's load of the next family was refused ("no loaded model can be evicted") because the previous family stayed resident | Probe fixed to unload every other resident model first, as `Executor.switchModel` does. Engine behaviour recorded: at one slot it does not evict an idle model itself |
| `log.refused-load-classifies` | No safe refusal flag exists at this pin | Synthetic fallback kept: it reads the recorded refusal tail (`oom-preflight.log`) |

Observed once, not a probe: with about 170–445 MB free, a chat request's prompt admission failed as a 400 (`Prompt (523 tokens) requires ~993MB GPU memory but only …`), which the app maps to `badRequest` (not retryable) instead of `enhancerOutOfMemory`. It could not be forced on a healthy engine, so no probe pins it; if it shows up in the field, map that 400 to `enhancerOutOfMemory` in `EngineError`.
