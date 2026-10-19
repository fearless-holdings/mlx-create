# LLD: LoRA library and stack

Implements HLD D34 and the plan `docs/plans/2026-10-19-1341-feat-lora-support-and-management-plan.md`. Local `.safetensors` files only; Civitai/CivArchive is out of scope.

## Data and files

- Table `lora` (migration `v4-lora`, `LoRARecord`): id, name, family, `sha256` (unique), `relative_path`, size, trigger words, notes, created.
- Files live at `Models/LoRAs/<family>/<sha10>-<slug>.safetensors`, outside `Weights`. Rows and jobs store the path relative to the Models root (D17). `LibraryStore` and `JobExecutor` both take `modelsRoot`.
- Import (`LibraryStore.importLoRA`): read the safetensors header only, classify by fingerprint, stream-copy to `.partial` while hashing, resolve duplicates on the unique hash (`.duplicate`, nothing added), auto-suffix a clashing name, move into place, insert the row. `.partial` files under `LoRAs` are swept at open.
- Delete (`deleteLoRA`) runs in one write transaction. It refuses while a queued, running, paused or retryable-failed job holds the LoRA. `enqueueJob` validates each frozen LoRA (row, hash, file) inside its own write transaction, so a delete cannot slip between them.

## Fit

`families.json` carries `loraFingerprints` per family: alternative layouts. Each has tensor-name patterns (prefix, suffix or substring, all required), shape hints (a tensor whose name matches must have `shape[dimension] == size`, all required) and block counts. Wrapper prefixes (`base_model.model.`, `diffusion_model.`, `transformer.`) are stripped before matching. A family with no fingerprint accepts no LoRAs. Flat kohya names (`lora_unet_...`) are not supported. Fit is per family; klein 4B and 9B are told apart by shape (3072 vs 4096), not by name.

Block counts are the full model's block count. A LoRA may cover only some blocks (partial coverage is accepted), but a file matches only when every `family.N.` index is below the count, so a file reaching a block the model lacks matches nothing. The counts are observed: highest index in the real samples plus one (klein BFL 5 double blocks, klein diffusers 8, Krea 28, Qwen 32). They are not read from model configs, so a model with more blocks would be refused, never misclassified.

Fingerprints come from real LoRA headers, read by HTTP range on 2026-10-19. The fixtures in `Tests/MCCatalogTests/Fixtures/lora-*.json` keep the real tensor names and shapes, reduced to one tensor per module name plus the first and last block; the tests assert the classification on those fixtures. Samples: FLUX.2 klein 4B (BFL layout, hidden 3072, `double_blocks` 0-4 seen); klein 9B in BFL (hidden 4096, `double_blocks` 0-7) and diffusers layouts (`transformer_blocks` 0-7, `.lora_A.weight` keys); Qwen-Image 2.1 attention-only (`.lora.down.weight`) and ai-toolkit (`.lora_down.weight`, with `img_mlp.gate_up`), hidden 4096, blocks 0-31; Krea-2 native (`blocks` 0-27, hidden 6144, `attn.wq`) and diffusers alias (`transformer_blocks` with `attn.to_gate`).

Discriminators. Klein's diffusers layout uses `.lora_A.weight` and Qwen's uses `.lora.down.weight` or `.lora_down.weight`. Klein and Qwen attention share hidden 4096 and the same module names, so on attention-only files the key suffix is the only separator. Klein's diffusers alternative requires `.lora_A.weight`, and Qwen's attention alternatives require their down suffixes. Partial-block Qwen files (blocks 0-7) therefore classify as Qwen, and a klein file never falls into Qwen by reaching a low block index.

Known residual risk: a klein file in diffusers names that uses `lora_down` or `lora.down` keys and touches only blocks 0-7 matches Qwen. No such sample exists, so this is checked by simulation only, not by a real file.

Known gap: keys outside the listed block runs (`img_in`, `txt_in`, time embeddings, Krea `txtfusion`) are not checked against any pattern, because no fingerprint lists them. A file that mixes valid family keys with foreign keys is still accepted.

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
- Not yet verified: fingerprints for FLUX.2 klein and Qwen match the real headers but have not been checked against a loaded model, and the GUI is untested.
