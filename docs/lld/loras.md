# LLD: LoRA library and stack

Implements HLD D34 and the plans `docs/plans/2026-10-19-1341-feat-lora-support-and-management-plan.md` (local import) and `docs/plans/2026-10-19-1605-feat-civitai-lora-browse-download-plan.md` (Civitai browse and download, see the last section). CivArchive stays deferred.

## Data and files

- Table `lora` (migration `v4-lora`, `LoRARecord`): id, name, family, `sha256` (unique), `relative_path`, size, trigger words, notes, created. Migration `v5-lora-source` adds a nullable `variant` and the `lora_source` table (last section). Existing rows keep a null variant.
- Files live at `Models/LoRAs/<family>/<sha10>-<slug>.safetensors`, outside `Weights`. Rows and jobs store the path relative to the Models root (D17). `LibraryStore` and `JobExecutor` both take `modelsRoot`.
- Import (`LibraryStore.importLoRA`): read the safetensors header only, classify by fingerprint, stream-copy to `.partial` while hashing, resolve duplicates on the unique hash (`.duplicate`, nothing added), auto-suffix a clashing name, move into place, insert the row. `.partial` files under `LoRAs` are swept at open.
- Delete (`deleteLoRA`) runs in one write transaction. It refuses while a queued, running, paused or retryable-failed job holds the LoRA. `enqueueJob` validates each frozen LoRA (row, hash, file) inside its own write transaction, so a delete cannot slip between them.
- Delete also removes the LoRA's `lora_source` row (cascade) and its preview file, in the same transaction; a failed file removal rolls back.

## Fit

`families.json` carries `loraFingerprints` per family: alternative layouts. Each has tensor-name patterns (prefix, suffix or substring, all required), shape hints (a tensor whose name matches must have `shape[dimension] == size`, all required) and block counts. Wrapper prefixes (`base_model.model.`, `diffusion_model.`, `transformer.`) are stripped before matching. A family with no fingerprint accepts no LoRAs. Flat kohya names (`lora_unet_...`) are not supported. Fit is per family; klein 4B and 9B are told apart by shape (3072 vs 4096), not by name.

The size variant (`4b` or `9b`) is reported with the family id: `classifyLoRA` returns an optional `variant` from each fingerprint, so a 9B file is not gated as 4B. Klein's `4b` and `9b` fingerprints carry the variant; Krea and Qwen have none.

Block counts are the full model's block count. A LoRA may cover only some blocks (partial coverage is accepted), but a file matches only when every `family.N.` index is below the count, so a file reaching a block the model lacks matches nothing. The counts are observed: highest index in the real samples plus one (klein BFL 5 double blocks, klein diffusers 8, Krea 28, Qwen 32). They are not read from model configs, so a model with more blocks would be refused, never misclassified.

Fingerprints come from real LoRA headers, read by HTTP range on 2026-10-19. The fixtures in `Tests/MCCatalogTests/Fixtures/lora-*.json` keep the real tensor names and shapes, reduced to one tensor per module name plus the first and last block; the tests assert the classification on those fixtures. Samples: FLUX.2 klein 4B (BFL layout, hidden 3072, `double_blocks` 0-4 seen); klein 9B in BFL (hidden 4096, `double_blocks` 0-7) and diffusers layouts (`transformer_blocks` 0-7, `.lora_A.weight` keys); Qwen-Image 2.1 attention-only (`.lora.down.weight`) and ai-toolkit (`.lora_down.weight`, with `img_mlp.gate_up`), hidden 4096, blocks 0-31; Krea-2 native (`blocks` 0-27, hidden 6144, `attn.wq`) and diffusers alias (`transformer_blocks` with `attn.to_gate`).

Discriminators. Klein's diffusers layout uses `.lora_A.weight` and Qwen's uses `.lora.down.weight` or `.lora_down.weight`. Klein and Qwen attention share hidden 4096 and the same module names, so on attention-only files the key suffix is the only separator. Klein's diffusers alternative requires `.lora_A.weight`, and Qwen's attention alternatives require their down suffixes. Partial-block Qwen files (blocks 0-7) therefore classify as Qwen, and a klein file never falls into Qwen by reaching a low block index.

Qwen PEFT layout (2026-10-20). A Civitai file can use PEFT keys with no wrapper prefix, an adapter infix and unfused MLP names (`transformer_blocks.N.attn.to_q.lora_A.default.weight`, `img_mlp.gate_layer`, `img_mlp.proj`; sample: Radiance Chrome Voluptuous, QwenImage2.1 v1.0, 448 tensors, header read by range request). Qwen's fourth fingerprint keys on `img_mlp.gate_layer` instead of a key suffix, so any suffix style classifies. Klein names its MLP `ff.linear_in` and never uses `img_mlp.gate_layer`, so the two stay apart. A Qwen LoRA that trains attention only and uses `.lora_A` keys is still unmatched, because on those files the suffix was the only separator from klein 9B. Kohya flat names (`lora_unet_...`), which the engine accepts, are still not classified.

Engine support (2026-10-21). Engine v26.10.2 had no Qwen-Image LoRA key mapping, so a Qwen LoRA ended in HTTP 400 "no modules matching" and the app greyed Qwen LoRAs behind an `engineAppliesLoRAs` flag. Upstream PR 849 shipped in v26.10.3-pre-release.1, which `engine.lock` now pins. The flag, `LoRAFit.engineCannotApply` and the library item's `engineBlockedReason` were removed in the same change, so Qwen LoRAs fit like any other family's. Verified against the real engine, see below.

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
- Not yet verified: fingerprints for FLUX.2 klein match the real headers but have not been checked against a loaded model, and the GUI is untested.

## Verified against the real engine (v26.10.3-pre-release.1, 2026-10-21)

Qwen-Image 2.1 Turbo (8-bit), launched as the app does, with two Qwen LoRAs from the library (`high-resolution`, `canon-ultrareal`; both classified `qwen-image-2.1-turbo` by the shipped importer):

- Each LoRA at strength 1.0 changes the image against the same seed without a LoRA, and the result is a coherent portrait (viewed). Generation took about 7 s at 512×512, 8 steps.
- A klein LoRA sent to the Qwen model still returns 400 `LoRA(s) have no modules matching this model's DiT`, so the error mapping above stays reachable.
- On the non-turbo 4-bit pack, strength -1.0 changes the image, strength 0 reproduces the no-LoRA image exactly, and two LoRAs at 0.7 differ from either alone.
- Not verified: the GUI path (stack row, Add, generate), and a LoRA that carries only attention keys with `.lora_A` suffixes (still unclassified, see "Fit").

## Civitai browse and download

Status: built per `docs/plans/2026-10-19-1605-feat-civitai-lora-browse-download-plan.md`. The unit suites (`swift test`) and the app build pass. One live run on 2026-10-19 and the earlier anonymous probe are the only evidence against real Civitai; the GUI and the real engine were not exercised. See "Observed" and "Not run" at the end.

### Civitai tab

- A "Civitai" tab beside Your LoRAs in the LoRA library sheet (HLD §10, D34). Results are LoRAs only, filtered by the selected model's Civitai base-model label (`civitaiBaseModels` in `families.json`). FLUX.2 klein 4B and 9B have separate labels. Labels seen 2026-10-19: `Flux.2 Klein 4B`, `Flux.2 Klein 9B`, `Krea 2`, `Qwen 2.1`. Matching is exact: `Flux.2 Klein` returned nothing. Mage-Flow was not probed and has no label, so it is not offered.
- A family chip overrides the filter for the session. "Show incompatible" removes the label filter, with the selected model's label sorted first.
- No selected model: the tab asks the user to select one and sends no request.
- NSFW results are hidden unless a persisted opt-in is on (off by default). Previews stay blurred until revealed, per session.

### Key and redirects (KTD2)

- The key lives in Keychain only. `Authorization: Bearer` goes only on https requests to `civitai.com`, never in a URL, never logged.
- The downloader follows redirects itself and drops the header on any host change or any non-https target. Foundation's default is not relied on. Only https URLs are followed.
- A 401 or 403 on the download URL means "needs key". A saved key that is still refused shows its own message, not a loop. Whether a 401 means a per-file login requirement or throttling is not established.

### Download path (KTD1, KTD3, KTD4, KTD10)

- One stream per file. The downloader does not require an ETag, because Civitai's CDN sends none; an interrupted download restarts from zero.
- Size cap: a fixed 4 GiB. Over the cap, or without free disk (the existing 1 GiB headroom), the request is refused before the file request is made.
- Header peek: after license acceptance, the safetensors header is range-read from the resolved CDN URL (8 bytes for the length, then the header, bounded by the existing 100 MiB limit) and classified. A refusal costs only those header bytes and writes nothing. A 401 or 403 here is the needs-key signal.
- Bulk transfer: streams to `Models/.partial/civitai/<versionId>.partial` while hashing. A running byte counter aborts and deletes the staged file if received bytes exceed the advertised size or the 4 GiB cap. The SHA-256 must match Civitai's. The file is then classified again, and that result is the authority.
- Commit: a staged-file entry point in `LibraryStore` shares the import's commit routine (duplicate, name-clash suffix, restored handling) and moves the file to `Models/LoRAs/<family>/<sha10>-<slug>.safetensors`. The staging directory lives outside `Models/LoRAs/`, so `sweepUnreferencedLoRAs` cannot delete a download in progress. It is swept at store open.
- A duplicate or restored commit adds no second LoRA row, but when the commit carries a Civitai source and the existing LoRA has none, the `lora_source` row is attached to the existing LoRA in the same write. An existing source is never overwritten.
- Cancel works until the commit's database write: a cancel that arrives after the transfer staged, or during the preview fetch, deletes the staged file and stores nothing.
- Stack (D51): after the commit and the library refresh, `loraCommitted` offers the stored (or duplicate) LoRA to `AppModel.attachDownloadedLoRA`. It goes on the stack at weight 1.0 when its family is the selected model's family and the stack has room; the row then reads "Added to the stack" (`CivitaiRowStatus.addedToStack`). Otherwise it stays in the library and the row reads "Added to your LoRAs". The row's action reads "Download and Add".

### Size variant

- `LoRAFingerprint` gains an optional `variant`, and `classifyLoRA` reports it with the family id. Klein BFL 4B (hidden 3072) gives `4b`; klein 9B (hidden 4096, BFL or diffusers layout) gives `9b`. Krea and Qwen give none.
- The variant is stored on the `lora` row. A LoRA whose variant differs from the selected model's is greyed out, for local imports and Browse alike. A null variant is never gated. The selected model's variant comes from its engine architecture string (`flux2-klein-4b` gives `4b`). The klein 9B string is unverified.

### lora_source table and v5 migration

- Migration `v5-lora-source` adds nullable `lora.variant` and the table `lora_source`, keyed by `lora_id` with cascade delete. Columns: Civitai model id, version id, page URL, license and commercial-use flags as JSON, `accepted_at`, preview path, preview NSFW level, and example prompts as JSON. `v4-lora` is not edited. `LoRARecord` decode stays strict, with no new required field.
- Local imports write no `lora_source` row. Civitai's `trainedWords` fill the LoRA's trigger words.
- Previews: one image per download, fetched once from Civitai's image CDN, re-encoded to HEIC with `Thumbnails`, and stored under the library's preview directory outside `Models/LoRAs/`. Deleting the LoRA removes the file. A preview failure never fails the download.

### Curated shelf and always-on LoRAs

Implements HLD D43 to D47. Plan: `docs/plans/2026-10-22-1149-feat-curated-lora-supply-plan.md`.

- **Catalog data.** The signed catalog gains an optional top-level `lora_shelf` array, omitted from the encoding when empty so existing catalog bytes are unchanged. An entry carries family, role, `nsfw`, source kind (Civitai or Hugging Face) and identifiers, filename, SHA-256, size, license text, trigger words, tested scale, community rating, `tested_engine` and `always_on`. A family without `loraFingerprints` accepts no shelf entry.
- **Shelf.** The Recommended tab (the shelf) in the LoRA library, filtered by the selected family and `civitaiIncludeNSFW`. Picking an entry runs the license sheet, downloads (SHA-256 verified), adds the LoRA to the stack at its tested scale, and its trigger words reach the enhancer through `enhancementLoRAs()`. An entry whose fetch returns not-found shows "no longer available". An empty role renders nothing.
- **Provenance.** `lora_source` generalizes with a source kind and nullable Civitai ids through a new table-rebuilding migration. `v5-lora-source` is not edited. `civitai.red` URLs resolve by id through `civitai.com`.
- **Cap.** The per-request cap is 8 minus the family's always-on count, enforced in `addToLoRAStack` and `setLoRAStack`. The refused-add message states the cap.
- **Always-on.** A `lora` row with a non-null `always_on_scale` (migration `v10-lora-always-on`), applied at that scale by `JobExecutor.generateNext` after the user's LoRAs are frozen and never stored in the request or the image record. `loras()` (so the library list, picker and `enhancementLoRAs()`) skips such rows, `loraTotalBytes()` excludes them, gallery facets read saved image settings that never contain them, and failure copy names only the job's own LoRAs. `deleteLoRA` refuses one, and the open-time sweep keeps its file because the row still names it. The executor derives the per-request cap from the always-on rows it applies; the app caches the per-family count when the library refreshes. A row whose file is missing or changed is skipped, never a failure. One `loraRejected` retry without the always-on set, then the user-LoRA failure copy.
- **Always-on and the stack.** Always-on LoRAs yield to the user's stack: the executor sends at most `8 - stack size` of them, and a stack over 8 fails with the engine's plain limit, so no message or log reveals how many a family has. A stack entry naming a hidden row fails as missing. Importing, downloading or picking the file an always-on row names stops with neutral copy and never resolves to that row, and hidden names stay out of the name-clash set.
- **Krea 2 text-fusion layout.** The refusal-reduction file is full-rank `lora_down`/`lora_up` under `diffusion_model.txtfusion.layerwise_blocks.*` and `.refiner_blocks.*` (2560-wide attention), not the `lora_A`/`lora_B` layout. `families.json` carries a third `krea-2-turbo` fingerprint for it, read from the real header: block counts 2 and 2 are what that full-rank file covers. Marking a row always-on is the catalog install step (U9); until the curation verdicts approve an entry, no family ships one.
- **Always-on install (D45).** `AlwaysOnProvisioner` (owned by `ShelfModel`) installs the catalog's `always_on` entries for every family the user has a model for. It runs when the model list refreshes and when a generation starts, never shows progress, and a row is committed with `LibraryStore.commitAlwaysOnLoRA`, which stores the hidden row in the same write as the file move and refuses content the user already has as an ordinary row. The Civitai file is login-only, so it is fetched with the user's saved Civitai key (the key goes only to `civitai.com`); with no key, or after a failure, nothing is requested again for ten minutes and the family generates without it (R13). A row whose file went missing or changed size is fetched again. The disclosure is the family's model license sheet (`PendingLicense.notices`) and `NOTICE`, nowhere else (D46).

### Deferred and unverified

- Deferred: CivArchive, fetch by pasted link or hash, drop-a-PNG fetch, update checks, and parallel downloads. The curated shelf is no longer deferred; see "Curated shelf and always-on LoRAs".
- Not verified: see "Not run" below.

### Observed

- **Live download, 2026-10-19, no key, production transports (throwaway harness, since deleted).** A Civitai search for `Flux.2 Klein 4B`, most downloaded, NSFW off, returned 20 models, 16 of them with a `.safetensors` version under 100 MB. The first candidate, "Klein Anatomy / Quality Fixer" (version "Klein 4B", 11,571,232 bytes), downloaded anonymously: the header peek classified it `flux2-klein` variant `4b`, the streamed file matched Civitai's SHA-256, and `commitStagedLoRA` wrote the `lora` row, the `lora_source` row with its page URL, and the file at `LoRAs/flux2-klein/<sha10>-<slug>.safetensors`. The preview was fetched once and stored as a 29,867-byte HEIC. The staging folder ended empty. That version lists no `trainedWords`, so trigger-word filling from Civitai was not observed live; it is covered by an app test with a scripted response.
- **Tests.** `swift test` passes in full. Downloader behavior (key reaching only the API host, redirect to another host name, same-host redirect to http refused with the key dropped, header-peek refusal costing only header bytes, over-send abort, expired signed URL re-resolved once, wrong hash and wrong length rejected) runs against a local Range server that mimics Civitai. No live Civitai call is in the permanent suite.

### Not run

- The 401 path against real Civitai: the live run hit no gated file, so the needs-key state was only exercised against the local server. The earlier probe saw 401 on 14 of 30 sampled download URLs; whether that is a per-file login requirement or throttling is still unknown.
- ETag absence, the redirect host and Range support on the real CDN were not captured as headers in the live run. The download succeeded and matched the advertised length, which is consistent with them but does not prove them.
- Generation with a Civitai-downloaded LoRA on the real engine. The FLUX.2 klein 4B model is not on disk and is about 5 GB, so it was not downloaded without asking. The fit check for klein rests on header matching only (see "Fit").
- The GUI: no one has looked at the Civitai tab, the license sheet, blur behavior, or the detail pane in Your LoRAs in the running app. The app builds with xcodegen and xcodebuild.
- Klein 9B classification against a loaded model, the klein 9B engine architecture string, the 4 GiB cap in practice, and Mage-Flow's Civitai label. (Qwen classification against a loaded model was verified 2026-10-21, see above.)
