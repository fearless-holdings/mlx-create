# LLD: On-device calibration and time estimates

Modules: `MCCatalog` (`reference_timing` field, `docs/lld/models.md` §2), `MCGeneration` (executor drain step, `Calibrator`, `SpeedEstimator`, timing capture), `MCLibrary` (the two timing tables, schema v11), `AppModel` (candidate supplier and triggers), `MCApp` (estimate display and the queue header). Implements HLD §8.5 and §9 under D16 and D48. The decisions KTD1 to KTD11 below are the contract for the code in `docs/plans/2026-10-23-1600-feat-on-device-calibration-plan.md`.

## 1. Scope

| In scope | Out of scope |
|---|---|
| Empty-engine calibration per engine version, run by the executor (KTD1-KTD3) | Using speed in the recommender's pick (D48) |
| Continuous timing of every real generation (KTD4, KTD8) | Per-chip reference timings, the `HardwareProfile` table and a chip-keyed catalog (D48) |
| Optional signed `reference_timing` catalog field (KTD8) | A recalibrate, skip, progress or cancel control (D48) |
| Estimate display in the model browser, composer and queue header (R8) | Speed controls, an Advanced panel and sampler choices (D14) |
| | Queue-wide ETA totals, learning a scale from samples at other sizes (KTD6), video models (D7) |

## 2. Contract

KTD1 to KTD11 are the contract for the code.

- **KTD1. Calibration is an executor step, not a job row.** `JobExecutor.drain` gets a step that runs when it finds no queued job. It never calls `enqueueJob`, `saveImage` or `store.jobs`. This avoids four traps found in research: `run` fails any job whose mode is not `t2i` (`Executor.swift:138`); `jobs(status:)` and `nextQueuedJob` filter by status only (`LibraryStore.swift:398-436`), so a calibration row would show in the queue strip; `enqueueJob` writes a prompt-history row in its transaction (D39); and every reader would need the skip filter that `docs/solutions/integration-issues/hidden-lora-rows-every-query-must-skip-them.md` documents. Ordering falls out of drain being serial.
- **KTD2. "Waits its turn" rules.** Inside the executor's single drain loop: wait for the lease gate (`waitWhileLeaseHeld`, `EnhancerLease.swift:123`), look for a queued job, and run calibration only when `nextQueuedJob()` is nil. If a job exists but the queue is paused, the drain ends, so calibration also waits (queued generation blocks it); with no job, a pause does not stop calibration. Both the lease wait and the queue read suspend the actor (`Executor.swift:84-85`), so a lease can begin between them, as `run()` already guards against (`Executor.swift:135-136`). The calibration step therefore re-checks `enhancerLeaseHeld` and `currentJobID` after the queue read returns, in the same synchronous segment that sets `calibrationRunning = true`; if either changed, it loops back to the top of the drain instead. `acquireEnhancerLease` and `selectModel` gain a wait on that flag next to their existing `currentJobID` and lease waits (`EnhancerLease.swift:54-66`, `Executor.swift:111-119`). After calibration, drain loops again, so a job submitted meanwhile starts next. `start()` is a no-op while a drain is in flight (`Executor.swift:67-68`), so a wake-up arriving while the drain is mid-read would be lost: `start()` records a `pendingKick` flag in that case, and the drain checks and clears it before it returns, looping once more if it was set. A lease release and a finished install both wake the executor this way (`AppModel.startDraining` delegates to the executor's `start()`), so a due calibration is not left waiting for an unrelated trigger. A due calibration yields nothing mid-run: it is two renders, and the lease waits for it.
- **KTD3. Empty-engine procedure.** Under `serialized`, list `client.models().filter(\.loaded)`, unload every one, then load the calibration model. This is the same loop `switchModel` uses (`Executor.swift:122-131`), without the "already resident" short-circuit. A load that returns `EngineError.outOfMemory` is retried twice, 30 s apart, never with `--skip-mem-preflight` (`docs/lld/engine.md` §5.9, §5.10). After calibration the calibration model stays resident, because the next generation's `switchModel` handles any difference.
- **KTD4. What one measurement is.** Two renders at the calibration model's family `defaultSize` and default steps (`nil` steps for families where `stepsAreFixed`, `nil` guidance, no LoRAs, fixed seed, fixed benign prompt). The first render absorbs first-run costs and is discarded. The second yields `seconds`, the time from opening the generation stream to its completed frame, taken with `ContinuousClock`. Model load is outside it, because residency is settled before the stream opens. Real generations use the same definition (KTD7), and the reference timing (KTD8) is produced by the same code, so the three agree by construction. No timing field exists in the engine's responses (`SSELineParser` decodes none), so this is client wall-clock. The stage names in progress frames are undocumented, so nothing depends on them.
- **KTD5. Baseline lifecycle.** One `calibration_baseline` row per engine version, written only after the measured render succeeds, so a quit or crash mid-run leaves nothing and the run repeats next launch. Calibration is due when a candidate model exists and no row exists for the running engine version. The version comes from `ENGINE_VERSION` through `bundledEngineVersion()` (`AppModel.swift:313-317`). When it is `nil` (under `swift test`), calibration and timing capture are off, so tests never calibrate by accident. A failed attempt sets an in-memory "tried this launch" flag. Nothing is persisted for failures.
- **KTD6. Estimate formula and tiers.** `factor = baseline.seconds / baseline.referenceSeconds` for the calibrated model. For any model with a reference timing, `estimate = reference.seconds × factor × (pixels / referencePixels) × (steps / referenceSteps)`. This is an approximation: one model sets the factor for all, and cost is assumed linear in pixels and steps. It is why the UI says "estimate". A setup with at least three samples for the exact key (current engine version, model, width, height, steps, LoRA count) is shown as measured: the median of its most recent five. No estimate is made without a baseline and a reference timing. Reference timings are measured without LoRAs, so estimates for families with always-on LoRAs (D44) omit that overhead until samples exist. This is a known limit, recorded in §4.
- **KTD7. Continuous timing.** `generation_timing` rows hold engine version, model id, width, height, steps (from the stream's `total`), LoRA count (files in the actual engine request, including always-on), seconds and a timestamp. They are written in `generateNext` after the successful stream, best-effort (`try?`), only when `engineVersion` is non-nil. Each key keeps its newest five rows, which is all the estimator reads (KTD6). Rows under other engine versions are never read, so no cleanup runs.
- **KTD8. Catalog field.** `reference_timing: { width, height, steps, seconds }` on `CatalogModel`, decoded with `decodeIfPresent` and encoded only when set, which is the `recommend_rank` and `kind` precedent. `schema_version` stays 1 and every re-sign bumps `sequence` (`docs/lld/models.md` §2). `CatalogBuilder` and `CatalogDiff` learn the field, or `sign --acknowledge-diff` would approve timing changes unreviewed (the KTD9 trap in `docs/plans/2026-10-22-1149-feat-curated-lora-supply-plan.md`).
- **KTD9. Candidates come from the app.** The executor does not know the catalog or the installed set. `AppModel` supplies an async closure returning `[CalibrationTarget]` (model id, `ModelFamily`, `ReferenceTiming`) for installed, selectable image models that have a reference timing. The selected model comes first and the rest follow registry family order (`ModelSelection.defaultModelID`). It returns an empty list while the engine is not ready. The first target is the calibration model.
- **KTD10. Failure and retry.** OOM load: retried per KTD3. A crash, connection loss or other error ends the attempt with a log line and the in-memory flag. The engine supervisor's own restart budget (3 per 5 min, `docs/lld/engine.md` §5.7) is untouched, and a failed calibration is never reported as a job failure.
- **KTD11. Visibility.** A new executor event `.calibrationChanged(Bool)` drives a `calibrating` case in the queue header state. It has no pause or cancel affordance. A user whose first generation lands behind calibration sees it queued under that header.

## 3. Measurement

A measurement is defined by KTD4 and used in two places: the calibration renders and every real generation. Both record wall-clock seconds from stream open to the completed frame, so the reference timing, the baseline and the continuous samples are comparable by construction. A clock that includes model load, or a stream that reports stage timings, would break that comparison and is not used.

## 4. Estimate and known limits

Estimate (KTD6):

```
factor   = baseline.seconds / baseline.referenceSeconds
estimate = reference.seconds × factor × (pixels / referencePixels) × (steps / referenceSteps)
measured = median(newest 5 samples for key), shown when samples ≥ 3
```

Known limits. Each is accepted, and the UI labels any estimate as an estimate.

- **One factor for all models.** The factor comes from one model. The cross-model scaling is correct only if the bottleneck (memory bandwidth or GPU compute) is the same for each model. The smoke test in U9 measures the error on a second model, and the result is recorded here.
- **Linear cost.** Cost is assumed linear in pixels and steps. Attention and fixed per-step overhead make this approximate, most visibly at very different sizes.
- **No LoRA term.** Reference timings are measured without LoRAs. Families with always-on LoRAs (D44) are underestimated until samples exist for the exact key.
- **Single noisy baseline.** A first-render outlier or a noisy download can skew the factor. The discarded warm-up mitigates the first. One bad baseline persists until the next engine version, while continuous samples correct the installed models in the meantime.
- **Memory-limited Macs.** On a 16 GB Mac a candidate may not fit. The load is refused and retried (KTD3, KTD10), then calibration gives up for the launch. Estimates for that Mac then rely on continuous samples only.
- **Queue wait.** After the first install with an empty queue, calibration starts at once and the first Generate waits for two renders. A paused queue with nothing queued also starts it.
- **Idle eviction.** The procedure unloads and loads explicitly, so the measurement does not depend on whether a model was warm (`docs/lld/engine.md` §6 item 3).

## 5. Data

Added by the `v11` migration (`MCLibrary`). Names are directional until U3 lands.

| Table | Columns | Written by |
|---|---|---|
| `calibration_baseline` | `engine_version` (key), `model_id`, `width`, `height`, `steps`, `seconds`, `reference_seconds`, `measured_at` | calibration, once per engine version |
| `generation_timing` | `engine_version`, `model_id`, `width`, `height`, `steps`, `lora_count`, `seconds`, `created_at` | each real generation |

Neither table is a job, an image, a gallery entry, a prompt-history entry, a thumbnail or a library row (R4). Neither is read by any query that lists user content.

## 6. Privacy

Timing data stays on the device (R9). No timing value, model name from calibration, or calibration result leaves the device, and nothing in this design adds a network call. The catalog's `reference_timing` is the only timing that arrives from outside, and it is read-only input.

Known conflict, not resolved here: HLD §8.10 (opt-in analytics) lists `duration` and `chip class` on the generation-completed event. That event predates D48 and is not changed by this design. Whether those fields stay is the author's decision, and it must be settled before any build that sends analytics ships.

## 7. Catalog field

`reference_timing` is specified in `docs/lld/models.md` §2 (HLD D48). It is optional, image models only, written only when set, and placed after `recommend_rank` in key order. Validation rules and the `CatalogDiff` behaviour are the same as for `recommend_rank` and are covered by the catalog tests in U2.
