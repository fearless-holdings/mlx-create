# AGENTS.md: mlx-create

mlx-create is a commercial, native macOS app (macOS 26.2+, Apple Silicon, 16 GB minimum) for local image and video generation. It is Auto1111-class in scope but Mac-native. Inference runs in a bundled, pinned **upstream mlx-serve** binary, which the app drives over localhost HTTP/SSE.

## Status and source of truth

- **Phase:** the text-to-image vertical slice is implemented on branch `feat/t2i-generation-core` (a git repo; app code in `Sources/`, `App/`, `scripts/`). Later phases follow the HLD.
- **`docs/HLD.md` is the source of truth.** Decisions carry IDs (`D1`–`D25`), as do upstream engine requests (`F1`, `F3`–`F5`). Cite them in plans, PRs and commit messages.
- **Changing a decision:** update the HLD decision log first, then the code. Never let code silently diverge from a `D*` entry. If a task seems to need breaking one, stop and ask the user.
- **Planned layout:** see HLD §6 (Swift modules `MCEngine`, `MCCatalog`, `MCLibrary`, `MCModels`, `MCEnhancer`, `MCApp`) and §9 (data model, on-disk layout). Once real build and test commands exist, record them here in a **Commands** section.

## Non-negotiables

1. **No content filtering anywhere:** no prompt filters, no output classifiers, no refusal paths (D3/G6). The only content-related UI is NSFW opt-in and blur in the model browser (D15).
2. **No inference in the app process.** All generation and LLM work goes through the engine child process.
3. **The engine is stock upstream.** Never vendor, patch, or commit mlx-serve source. Engine changes go upstream as PRs (HLD §7.2). The app consumes them only through a tagged release pinned in `engine.lock`.
4. **The engine is private:**
   - Always launch it with `--host 127.0.0.1` and a random per-launch key passed via `--api-key-env` plus `--api-key-strict`. Without `--api-key-strict`, upstream exempts loopback callers from the key, and argv is world-readable (`docs/lld/engine.md` §5.2).
   - Upstream defaults to `0.0.0.0`, so never rely on defaults.
   - LAN share and discovery stay off.
5. **Nothing is written to `~/.mlx-serve`, and other tools' model folders are not scanned (D17).**
   - Launch the engine with `HOME=<AppSupport>/Engine`.
   - Keep `Engine/.mlx-serve/models` as a symlink to `<Models>/Weights` (HLD §7.4).
6. **Only `.safetensors` weights.** Reject `.ckpt`, `.pt` and `.bin`, because pickle formats can execute code.
7. **Privacy:**
   - Prompts, images, file names, Civitai item IDs or names, and API keys never leave the device.
   - Analytics are opt-in and content-free (HLD §8.10).
   - The Civitai key lives in Keychain only, and is never logged.
8. **Licenses:** show the model license and require acceptance at download (D20). Never redistribute weights.
9. **Scope guards:**
   - v1 executor accepts only `t2i`, but the data model stays mode-agnostic (D7).
   - Out of scope: sampler pickers (D14), tags, ratings and smart collections (D10), SDXL/SD1.5-family engines (D5), and ControlNet.

## Engine facts (upstream mlx-serve)

Read upstream source at the pinned tag, either on GitHub or in a throwaway clone outside this folder (`git clone --depth 1 --branch <tag> https://github.com/ddalcu/mlx-serve /tmp/mlx-serve-ref`). Never add it to this repo. HLD citations (`src/…`, `app/…`) refer to commit `1c34059`. Re-check them against the current pin before relying on line numbers.

### Request behaviour

- **One job at a time.** Media endpoints are synchronous and handle a single generation. The app owns the queue (D13).
- **Batching and samplers:** there is no `n` batch field and no sampler field. Batch count means N requests.
- **Cancellation:** close the connection, i.e. cancel the Swift task. The engine aborts the denoise loop when the client disconnects.
- **Seed:** always send an explicit `seed`. The engine default is a constant `42`.
- **SSE events:**
  - `{"type":"progress","stage","step","total"}`
  - `{"type":"error","message"}`
  - a final event carrying the base64 PNG

### Previews

Step previews currently exist **only for video** (`"preview": true` together with `"stream": true`). Image previews arrive with upstream F1. Until then, the UI shows step progress only, and the client must tolerate preview fields being absent.

### LoRAs

- Field names: `lora_paths` (JSON array of **absolute** paths) and `lora_scales`.
- Limits: at most 8 per request. Scales of −20…20 are valid.
- Accepted only from loopback.
- An incompatible LoRA returns HTTP 400 "no modules matching". Pre-check compatibility locally from the safetensors header (key names **and** tensor shapes, HLD §8.6). Treat the engine's 400 as the final authority.
- App side: LoRAs live in the `lora` table and under `Models/LoRAs/<family>/` (HLD D34, `docs/lld/loras.md`). Fit comes from per-family `loraFingerprints` in `families.json`; a family without one accepts no LoRAs. Take new fingerprints from a real LoRA header, never from guessed key names.
- The engine accepts LoRA paths outside `--model-dir` (verified v26.10.2), and its real 400 text contains `no modules matching`.

### Per-family controls

- `guidance_scale` only works on some families. Distilled and turbo models ignore it, so hide CFG there.
- Allowed sizes differ by family: FLUX.2 klein takes multiples of 32 in [256, 1536] at the pinned engine (D25), and Krea takes multiples of 16 in [256, 2048].
- Drive the UI from family capability records (HLD §8.3–8.4). Never hard-code knobs per screen.

### Other behaviour

- **Model lifecycle:**
  - `POST /v1/load-model` warms a model before use.
  - `POST /v1/unload-model` frees it.
  - `POST /v1/models/rescan` picks up new checkpoints or LLMs after install.
  - LoRAs need no rescan.
- **Video:** the endpoint returns raw `rgb8` frames plus `pcm_s16le` audio. The app muxes them with AVFoundation (phase 3).
- **Health:** `GET /health` returns `status:"ok"` when the engine is ready.

## Reusing mlx-serve's Swift app code

HLD Appendix A lists the files worth reusing. The rules:

- **Copy and adapt, don't depend.** The upstream app target is tightly coupled to its menu-bar UI.
- Copy from the **pinned tag**.
- Keep each file's MIT attribution, and add a header with the upstream path and commit.
- Strip UI and global state as you port.
- Upstream code embeds prompt-rewriter text adapted from QwenLM (Apache-2.0). Carry that attribution into `NOTICE`.

## Engineering conventions

- **Language:** Swift 6 with strict concurrency.
  - Services are actors or `@Observable` types.
  - No `@MainActor` on domain services; keep it in the UI layer.
- **UI:** SwiftUI first. Use AppKit bridges where SwiftUI falls short: an `NSCollectionView` gallery for 10k+ items, and the zoomable canvas.
- **Persistence:** SQLite via GRDB, with explicit migrations and FTS5 for prompt search. No SwiftData.
- **Image I/O:**
  - Inject PNG metadata chunks without re-encoding: an A1111 `parameters` `tEXt` chunk plus an `mlx-create` `iTXt` JSON chunk (D12).
  - Generate thumbnails as HEIC via ImageIO.
- **Remote data:** the catalog, prompt packs and appcast are signature-verified before use. Downloads are SHA-256-verified before the atomic move into `Models/`.
- **Memory:**
  - Respect the per-tier policies (HLD §11).
  - On 16 GB, the enhancer LLM and the diffusion model are never resident together.
- **Errors users see** must be actionable. Map engine failures (OOM, LoRA mismatch, missing weights) to plain-language messages.
- Prefer boring, explicit code over abstraction. Add a protocol only where the HLD names a seam: `ModelSource`, `Entitlements`, `ModelFamily`, and the D30 network test seams `ModelTransport`, `CatalogTransport`, `HubClient`.

## Commands

- Library tests: `swift test` (library targets plus `MCCatalogTool`, Swift Testing). `MCModelsTests` start a local Range server and need `/usr/bin/python3` (skipped when absent); real-engine tests need `MLXC_ENGINE_BIN`.
- Catalog: `swift run mc-catalog verify Sources/MCCatalog/Resources/catalog.json` checks the bundled signed catalog. `mc-catalog keygen|build|sign` produce it; the dev private key lives at `~/.config/mlx-create/dev-catalog.key`, never in the repo. Production key and catalog URL are release prerequisites.
- Gotchas: the `.gitignore` rule is `/Models/` (root-anchored) so `Sources/MCApp/Models/` is tracked; the app is single-instance (`Engine/app.lock`); `kill`ing the app with SIGTERM can leave its `mlx-serve` child running, so check `pgrep mlx-serve` after a manual quit.
- App project: `xcodegen generate` (needs XcodeGen 2.46+, `brew install xcodegen`), then `xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build`. The generated `MLXCreate.xcodeproj` and `build/` are git-ignored.
- Engine embed runs as a post-compile script from `project.yml` (`scripts/embed-engine.sh`, pinned by `engine.lock`).

## Verification

- **Smoke-test against the real engine**, using the smallest model: FLUX.2-klein 4B 4-bit, about 5 GB.
  - Run the app or a throwaway harness.
  - Exercise the changed path.
  - Observe the result: image written, metadata present, row in the DB.
- **Ask before downloading large weights.** Video models and 8-bit packs run to tens of GB. Check free disk first.
- **Engine bumps** must pass the engine contract suite, a black-box HTTP test pack (HLD §7.3), before `engine.lock` changes.
- **Permanent tests** cover behaviour that matters to users:
  - queue state transitions
  - seed policies
  - metadata round-trip (write, then drop-to-restore)
  - LoRA compatibility classification
  - catalog signature rejection
  - tier fit bands

  Don't write tests that pin wording or wiring.
- **External APIs** (Civitai, CivArchive, Hugging Face):
  - Use recorded fixtures in tests.
  - Keep live calls light and respect rate limits.
  - CivArchive's API contract is unconfirmed (HLD §15). Verify it before building on it.

## Repo hygiene

- `.env` holds `ANTHROPIC_API_KEY`. Never print, log or commit it.
- When initialising git, add a `.gitignore` covering at least `.env`, build output, and any local engine or reference downloads, before the first commit.
- Keep `docs/HLD.md` current. Write component LLDs alongside it as `docs/lld/<component>.md`.
- **Update this file** when you establish a command, convention or gotcha that the next agent would otherwise rediscover. Keep entries short and factual.
