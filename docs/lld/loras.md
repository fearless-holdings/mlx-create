# LLD: LoRA library and stack

Implements HLD D34 and the plan `docs/plans/2026-10-19-1341-feat-lora-support-and-management-plan.md`. Local `.safetensors` files only; Civitai/CivArchive is out of scope.

## Data and files

- Table `lora` (migration `v4-lora`, `LoRARecord`): id, name, family, `sha256` (unique), `relative_path`, size, trigger words, notes, created.
- Files live at `Models/LoRAs/<family>/<sha10>-<slug>.safetensors`, outside `Weights`. Rows and jobs store the path relative to the Models root (D17). `LibraryStore` and `JobExecutor` both take `modelsRoot`.
- Import (`LibraryStore.importLoRA`): read the safetensors header only, classify by fingerprint, stream-copy to `.partial` while hashing, resolve duplicates on the unique hash (`.duplicate`, nothing added), auto-suffix a clashing name, move into place, insert the row. `.partial` files under `LoRAs` are swept at open.
- Delete (`deleteLoRA`) runs in one write transaction. It refuses while a queued, running, paused or retryable-failed job holds the LoRA. `enqueueJob` validates each frozen LoRA (row, hash, file) inside its own write transaction, so a delete cannot slip between them.

## Fit

`families.json` carries `loraFingerprints` per family: alternative layouts, each with tensor-name patterns, shape hints and required block counts. Wrapper prefixes (`base_model.model.`, `diffusion_model.`, `transformer.`) are stripped before matching. A family with no fingerprint accepts no LoRAs. Flat kohya names (`lora_unet_...`) are not supported. Fit is per family; klein 4B and 9B are not told apart.

Fingerprints come from real LoRA headers (read by HTTP range, 2026-10-19): FLUX.2 klein 4B (BFL layout, 5 double / 20 single blocks) and 9B (diffusers, 8 blocks), Qwen-Image 2.1 (diffusers, 32 blocks), Krea-2 (native 28 blocks, and the diffusers alias with `attn.to_gate`). Qwen's minimal `attn.to_q` pattern would also accept a hypothetical 32-block Krea-alias-shaped file.

## Job and record

`JobRequest.loras` freezes the enabled, fitting, non-zero rows at enqueue (max 8, order kept). The executor checks each file exists, sends absolute `lora_paths` and `lora_scales` (both omitted when empty), and saves `ImageSettings.loras` from the frozen entries, so a later rename does not change what an image records. The A1111 `parameters` line gains `Lora hashes` (first 10 hex of the SHA-256) only when LoRAs were used.

## Errors

- A missing file fails the job before the engine call, retryable, naming the LoRA.
- Engine HTTP 400 containing `no modules matching` maps to a non-retryable message that names the LoRA and model.

## Verified against the real engine (v26.10.2, 2026-10-19)

Krea-2 Turbo (mixed 4/8) with `gokaygokay/Krea-2-Realism-LoRA` (469 MB), launched as the app does (loopback, `--api-key-strict`, isolated `HOME`):

- The shipped importer classifies the file as `krea-2-turbo`.
- The engine accepts `lora_paths` pointing outside `--model-dir`. The image differs from the no-LoRA image for the same seed and is identical across two LoRA runs.
- Omitting both LoRA keys is accepted.
- A LoRA with no matching modules returns 400 `{"error":{"message":"LoRA(s) have no modules matching this model's DiT — wrong LoRA for this architecture?"}}`.
- A relative or missing path returns 400 `'lora_path'/'lora_paths' must be absolute path(s) to .safetensors file(s)`.
- The engine needs `POST /v1/models/rescan` after the model directory is set, and the load id is the full folder name, not the short id.
- Not yet verified: FLUX.2 klein and Qwen fingerprints against a loaded model (only header-matched), and the GUI.
