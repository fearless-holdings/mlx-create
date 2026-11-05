# AGENTS.md: mlx-create

mlx-create is a commercial, native macOS app (macOS 26.2+, Apple Silicon, 16 GB minimum) for local image and video generation. Its mission (`STRATEGY.md`) is to make uncensored generation free and easy: a one-time purchase (D40), with the expertise baked in so the user has nothing to learn. Inference runs in a bundled, pinned **upstream mlx-serve** binary, which the app drives over localhost HTTP/SSE.

## Status and source of truth

- **Phase:** the text-to-image vertical slice is implemented and lives on `main` (a git repo; app code in `Sources/`, `App/`, `scripts/`). Later phases follow the HLD.
- **`docs/HLD.md` is the source of truth.** Decisions carry IDs (`D1` upward; the newest is at the end of the HLD decision log), as do upstream engine requests (`F1`, `F3`–`F5`). Cite them in plans, PRs and commit messages.
- **Changing a decision:** update the HLD decision log first, then the code. Never let code silently diverge from a `D*` entry. If a task seems to need breaking one, stop and ask the user.
- **Layout:** see HLD §6 (Swift modules `MCEngine`, `MCCatalog`, `MCLibrary`, `MCModels`, `MCEnhancer`, `MCApp`) and §9 (data model, on-disk layout). Build and test commands are in **Commands** below.

## Non-negotiables

Rules 2–6 describe mlx-serve, today's only engine. HLD D41 allows a second bundled engine (e.g. for SDXL/Pony) once its own decision entry exists. Any such engine inherits the same rules: a separate child process, stock upstream pinned by release, loopback-only behind a per-launch key, its own `HOME` under `<AppSupport>`, and `.safetensors` only. Do not start engine work without that decision.

1. **No content filtering anywhere:** no prompt filters, no output classifiers, no refusal paths (D3/G6). The only content-related UI is NSFW opt-in and blur in the model browser and the LoRA library's Civitai tab (D15, D34).
2. **No inference in the app process.** All generation and LLM work goes through an engine child process.
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
  - Prompts, images, file names, and Civitai item IDs or names never leave the device to our servers or analytics. Civitai necessarily sees which LoRAs a user looks up and downloads (HLD §12).
   - Analytics are opt-in and content-free (HLD §8.10).
  - The Civitai API key lives in Keychain only. It is sent only over https to `civitai.com`, never to any other host and never in a URL. A redirect to another host drops it. It is never logged.
8. **Licenses:** show the model license and require acceptance at download (D20). Never redistribute weights.
9. **Scope guards:**
   - v1 executor accepts only `t2i`, but the data model stays mode-agnostic (D7).
   - Out of scope: expert knobs such as sampler pickers or an Advanced panel (D14, `STRATEGY.md` Boundaries), tags, ratings and smart collections (D10), SDXL/SD1.5-family engines until a D41 decision adds one (D5), and ControlNet.

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
- The engine accepts LoRA paths outside `--model-dir` (verified v26.10.2), and its real 400 text contains `no modules matching`. Qwen-Image 2.1 LoRAs apply from v26.10.3-pre-release.1 on (verified 2026-10-21); v26.10.2 returned that 400 for every Qwen LoRA.

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
- **Chat:** `POST /v1/chat/completions` streams OpenAI-style SSE. The enhancer sends plain text with `enable_thinking: false`, never a JSON schema (`Sources/MCEngine/ChatStream.swift`).

## Reusing mlx-serve's Swift app code

HLD Appendix A lists the files worth reusing. The rules:

- **Copy and adapt, don't depend.** The upstream app target is tightly coupled to its menu-bar UI.
- Copy from the **pinned tag**.
- Keep each file's MIT attribution, and add a header with the upstream path and commit.
- Strip UI and global state as you port.
- Upstream's prompt-rewriter (`PromptRewriter.swift`) carries no QwenLM text and no license header, so enhancer packs are written for this app. Credit mlx-serve by name in `NOTICE`.

## Engineering conventions

- **Language:** Swift 6 with strict concurrency.
  - Services are actors or `@Observable` types.
  - No `@MainActor` on domain services; keep it in the UI layer.
- **UI:** SwiftUI first. Use AppKit bridges where SwiftUI falls short: an `NSCollectionView` gallery for 10k+ items, and the zoomable canvas.
- **Locale-sensitive numbers:** SwiftUI's `Text("\(x)")` localizes an `Int` ("1.024" in a Germany region), so print pixel sizes and identifiers with `Text(verbatim:)`. Format decimals with `.formatted(.number.precision(.fractionLength(1)))`, never `String(format: "%.1f", …)`, which ignores the locale (audit V03). This Mac's locale (`en_US@rg=dezzzz`) reproduces both.
- **Design tokens:** views take spacing, radii, type and colour from `Sources/MCApp/Design/MCTokens.swift` (docs/design-audit/specs/V01). A literal spacing, radius, font or colour in a view needs a reason in a comment.
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
- **Formatting:** `.swift-format` (4 spaces, 140 columns, otherwise swift-format defaults) is the style, and the repo is formatted to it. The OMP harness runs `lsp.formatOnWrite` (sourcekit-lsp → swift-format) on every `edit`/`write` of a Swift file and rewrites the whole file, so write code the way the formatter would; do not hand-wrap or restyle against it. Format with `git ls-files '*.swift' | xargs swift format format --in-place --configuration .swift-format`; check with `swift format lint --strict --configuration .swift-format <files>`. Without `.swift-format` the harness falls back to 2 spaces / 100 columns and reindents whole files, so never delete it.
- **Lint:** the pre-commit hook (husky + lint-staged) runs `swift format lint --strict --configuration .swift-format` on staged `*.swift` files, so a lint error blocks the commit, and the `Lint` GitHub Actions workflow (`.github/workflows/lint.yml`) runs the same command over every tracked Swift file on PRs and pushes to `main`, so `--no-verify` or a clone without `npm install` does not get past review. Keep the whole tree clean: `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` must print nothing. A JSON key that is not lowerCamelCase (`b64_json`) gets a `CodingKeys` case, not a lint suppression.

## Commands

- Library tests: `swift test` (library targets plus `MCCatalogTool`, Swift Testing). `MCModelsTests` start a local Range server and need `/usr/bin/python3` (skipped when absent); real-engine tests need `MLXC_ENGINE_BIN`.
- Catalog: `swift run mc-catalog verify Sources/MCCatalog/Resources/catalog.json` checks the bundled signed catalog. `mc-catalog keygen|build|sign` produce it; the dev private key lives at `~/.config/mlx-create/dev-catalog.key`, never in the repo. Production key and catalog URL are release prerequisites.
- Catalog entries carry `kind`: `image` when absent, or `enhancer`. `mc-catalog build` writes it from the input entry.
- Gotchas: the `.gitignore` rule is `/Models/` (root-anchored) so `Sources/MCApp/Models/` is tracked; the app is single-instance (`Engine/app.lock`); `kill`ing the app with SIGTERM can leave its `mlx-serve` child running, so check `pgrep mlx-serve` after a manual quit. Another task may run its own `mlx-serve`, so when one is not yours match on the app's home path in argv (as `scripts/gui-smoke/run_smoke.py` does) before killing anything, never on the name alone.
- Enhancer gate: `scripts/enhancer-gate/run_gate.py`, run from an Eval Python cell. Method, results and removal conditions are in `docs/lld/enhancer.md`.
- LoRA gate: `scripts/lora-gate/run_gate.py`, run from an Eval Python cell with `--engine "$MLXC_ENGINE_BIN" --weights DIR --model-id ORG/NAME --scratch DIR` and one of `--candidates list.json` or `--local-dir DIR`. It pre-screens each candidate through `mc-catalog lora classify FILE [--family ID]` (header fit from `families.json`, never a Python copy), engine load, same-seed reproducibility and strength 0 against the no-LoRA baseline, and writes one verdict JSON per candidate to `scripts/lora-gate/results/`; images and engine state stay in the scratch dir. Invocation, candidate schema and verdict fields are in `scripts/lora-gate/README.md`.
- Tests that drive `AppModel` must `await model.start()` before `refreshModels()`. `refreshModels` waits on the engine gate, which opens only after `start`.
- Test sync rules (each one fixed a real flake):
  - Before `EngineStubProtocol.finishHeld`, call `harness.engineHasReceived(path, count:)`. Releasing before the request arrives finds nothing held, and the test times out.
  - After waiting on the store, wait on the model's projection (`queueHeader`, `runningProgress`, gallery) too, because it lands later.
  - Put test deadlines on `SuspendingClock`, never `Date()` or `ContinuousClock`. This Mac DarkWakes mid-run, and a wall-clock deadline then expires 0.3 s into a 10 s wait.
- `swift test` takes about 40 s here. Past 2 minutes it is hung: `pkill -f swiftpm-testing-helper; pkill -f swift-test`, then bisect with `--filter` per suite.
- App project: `xcodegen generate` (needs XcodeGen 2.46+, `brew install xcodegen`), then `xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build`. The generated `MLXCreate.xcodeproj` and `build/` are git-ignored.
- Engine embed runs as a post-compile script from `project.yml` (`scripts/embed-engine.sh`, pinned by `engine.lock`).
- Calibration (D48, `docs/lld/calibration.md`): the app times two empty-engine renders per engine version and stores a baseline in `calibration_baseline`; estimates scale each catalog model's `reference_timing` by it. To measure a new `reference_timing`, extract the pinned engine, point `MLXC_ENGINE_BIN`, `MLXC_MEASURE_MODEL_DIR` (a directory of model folders or symlinks) and `MLXC_MEASURE_MODEL_ID` at it, and run `swift test --filter ReferenceTimingMeasurementTests` from an Eval cell. It prints one `REFERENCE_TIMING` line to copy into `catalog/models.src.json`, then rebuild and sign the catalog. Measure on one Mac, with no other engine loaded. To watch a calibration live, launch the app with a throwaway home (`CFFIXED_USER_HOME`, see `docs/solutions/developer-experience/launch-app-with-empty-library-for-first-run-testing.md`) holding a symlinked model under `Models/Weights/`, then read `calibration_baseline` from `Library/library.sqlite`.
- Engine contract suite (D49, `docs/lld/engine-contract.md`): `python3 scripts/engine-contract/run_contract.py --models DIR --loras DIR [--write-lock]` from an Eval cell. Not part of `swift test` and not in CI: it needs the real models and the extracted engine. It extracts the locked engine, runs `swift test --no-parallel --filter MCEngineContractTests`, and writes `engine.lock`'s `contract_suite` only for a complete passing run of the locked version; without `--write-lock` it is a dry run that only reports.
- Engine lock check: `sh scripts/engine-contract/check_lock.sh engine.lock` fails unless `contract_suite` records a `pass` for the pinned `version`. CI runs it (`Engine lock`, ubuntu-latest); it compares versions, not probe sets, so an edited `version` needs a new recorded run.
- GUI smoke (D50, `docs/lld/gui-smoke.md`, `scripts/gui-smoke/README.md`): `python3 scripts/gui-smoke/run_smoke.py --models DIR --model-id ORG/NAME` from an Eval cell, with mlx-create quit. It drives the real app on the real engine through the `MLXCreateUITests` XCUITest target (generate one image, then gallery Reuse prompt / Reuse all settings) in a throwaway home, about 1 minute with a built app. Local only, not in `swift test` or CI. Exit 2 is NOT RUN (no model, mlx-create running, Developer Mode off, or a test that skipped itself), never a pass. One-time setup: `sudo DevToolsSecurity -enable` and answer the system authentication prompt at the Mac. Evidence lands in `build/gui-smoke/<timestamp>/`. Gotchas: never pass the home as a bare launch argument (the window will not open; use `-MLXCSmokeHome <home>`); cleanup matches the home path in argv, never process names; `UserDefaults.standard` is not isolated by `CFFIXED_USER_HOME`, so the runner restores the preferences the app wrote and fails the run if the real library changed.
- GUI smoke window placement: the run is pinned to the built-in display. A window on an external monitor makes XCUITest's `window.screenshot()` fail ("Failed to create screenshot"), so the runner moves it there through System Events (`WindowPinner`); no built-in display is NOT RUN. XCUITest cannot drag a window and the autosave key name embeds a memory address, so do not try those. Details in `docs/lld/gui-smoke.md` section 4.

## Verification

- **Smoke-test against the real engine**, using the smallest model: FLUX.2-klein 4B 4-bit, about 5 GB.
  - Run the app or a throwaway harness.
  - Exercise the changed path.
  - Observe the result: image written, metadata present, row in the DB.
- **GUI smoke before a UI pull request:** run the GUI smoke above. A UI change that passes `swift test` can still break the window; this is the check that opens it.
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
- `docs/solutions/` holds verified learnings from solved problems, grouped by category (for example `integration-issues/`). Search it before working on an external API or a recurring bug, and add one when a fix hides reasoning the code does not carry. Example: Civitai listing previews and NSFW signals.
- `docs/design-audit/` holds the 2026-10-30 UX/UI audit: `README.md` (ranked findings, execution order, smoke contract), one executable spec per finding in `specs/`, and `capture-kit.md` (screenshot, accessibility-dump and contrast tools the specs' acceptance checks use). Before changing UI a spec covers, read that spec and its "Depends on"; S08 and S09 need an HLD decision first. For dark-mode captures, the `-AppleInterfaceStyle Dark` launch argument has no effect: flip the system appearance (`capture-kit.md`, `dark.sh`) and flip it back.
- **Audit progress:** `docs/design-audit/README.md` "Progress" explains the tracking. When you ship a finding, update its Status row in §2, add a Resolution section to its spec, and put `Audit: <ID>` in the PR body and commit message.
- **Stacked PRs for multi-PR work:** when a plan or task splits into two or more dependent PRs, ship them as one stack with `gh stack` (extension `github/gh-stack`, read `.agents/skills/gh-stack/SKILL.md` first), not as separate branches off `main`. Create the stack before writing code, one concern per layer, foundations at the bottom. Name branches `<topic>/<concern>`. Always use the non-interactive forms (`gh stack init <branch>`, `gh stack add <branch>`, `gh stack submit --auto`, `gh stack view --json`); the bare commands open prompts or a TUI and hang the harness. Independent work gets its own stack or a plain PR. Each layer's PR still carries its `Audit: <ID>` trailer and its own GUI smoke evidence.
- **Update this file** when you establish a command, convention or gotcha that the next agent would otherwise rediscover. Keep entries short and factual.

<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them, including dynamic-dispatch hops grep can't follow. Name a file or symbol in the query to read its current line-numbered source. If it's listed but deferred, load it by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` prints the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->
