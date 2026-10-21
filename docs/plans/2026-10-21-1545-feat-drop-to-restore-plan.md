---
title: Drop-to-Restore - Plan
type: feat
date: 2026-10-21
---

# Drop-to-Restore - Plan

## Summary

Dropping an image file onto the canvas reads its generation data and fills the composer. The reader understands our own `mlx-create` chunk, the A1111 `parameters` text that Civitai images carry, and the EXIF comment that re-encoded JPEG and WebP files use. When the image's model is installed, every setting is applied. When it is not, a warning appears on the canvas and only the prompt, negative prompt, seed and aspect ratio are applied. A pure parser lives in `MCLibrary`; the apply rules live in a new `AppModel` extension; the drop target and banner live in `CanvasView`. HLD D38 records the rule before code.

## Problem Frame

A user finds an image on Civitai and wants its prompt without retyping it. Today only gallery Reuse restores settings, and only for our own images. `MetadataCodec.read` exists (`Sources/MCLibrary/MetadataCodec.swift`) but no app code calls it, and it ignores the `parameters` chunk that every A1111-compatible image carries. Almost every Civitai image was made with an SDXL-class checkpoint this app cannot run, so a naive "restore everything" would put foreign steps and CFG on a turbo model.

## Requirements

**Reading**
- R1. A dropped file yields generation data from, in order: the `mlx-create` iTXt chunk, the A1111 `parameters` tEXt/iTXt chunk, then the EXIF `UserComment` of JPEG and WebP.
- R2. A foreign A1111 text yields prompt, negative prompt, steps, CFG scale, seed, size, model name, and LoRA references: AutoV2 hashes (10 hex characters) from `Lora hashes`, weights from `<lora:name:weight>` tags paired to the hash entry by LoRA name, defaulting to 1.0 when no tag matches.
- R2a. When the `mlx-create` chunk has a newer `schema_version`, the reader falls back to `parameters` and the banner says the image is from a newer app version.
- R3. `<lora:…>` tags are removed from the restored prompt in every case; the engine does not read them.

**Applying**
- R4. The image's model counts as installed when exactly one selectable model matches by id or by case-insensitive last path component of the id (KTD3). Zero or several matches, or an image that names no model, count as not installed.
- R5. Installed: select the model and apply prompt, negative prompt, seed, size, steps, CFG and the LoRA stack as the image states them. The family still wins where it cannot honour a value: fixed-step families send no steps, families without guidance ignore CFG, a size off the grid snaps (KTD4).
- R6. Not installed: show a warning naming the image's model, or saying the image names none, or listing the candidates when several match, plus what was and was not applied. Apply prompt, negative prompt, seed and aspect ratio only. The selected model, steps, CFG and LoRA stack stay as they are. With no selectable family, the raw requested size is stored and the next model selection runs the normal `fit`.
- R7. A seed outside 0..<2^32 (including -1) is not applied; the seed policy is left as it was and the `dropNotice` banner says so (D23).
- R8. LoRAs apply only in the installed case. Foreign ones match by case-insensitive prefix of the library `sha256` against the 10-character AutoV2 value; our own images keep exact full-hash matching. Unmatched ones are named in `loraNotice` only; the banner does not repeat them.
- R9. A drop overwrites the composer without asking, as Reuse settings does. Gallery Reuse settings is unchanged.

**Surface**
- R10. The canvas is the drop target in every canvas mode, with a visible highlight while a file is dragged over it. The LoRA-file drop on the generation panel stays separate.
- R11. A file with no generation data, an unsupported file, or an unreadable file produces a plain-language message and changes nothing. A ComfyUI workflow chunk is named as unsupported.
- R12. The warning and the messages show as a dismissible banner on the canvas. The next drop, a successful Generate, or Dismiss clears it.
- R13. Only the first file of a multi-file drop is used, and the banner says so.

## Scope Boundaries

- No ComfyUI graph parsing, no download of missing models or LoRAs, no hash lookup on Civitai or CivArchive (HLD §8.9 mentions it; it stays deferred).
- No drag from a browser (remote URLs or image data); file URLs only.
- Gallery Reuse settings and its missing-model behaviour are untouched.
- No sampler, scheduler or `Model hash` handling (D14, D22).

## Key Technical Decisions

- KTD1. **Parsing is a pure value type in `MCLibrary`, separate from `MetadataCodec`.** `ImageGenerationData` carries optional fields plus a `source` (`.mlxCreate`, `.a1111`, `.exif`). The reader returns `ImageReadResult`: `.data(ImageGenerationData)`, `.comfyUI`, or `.none`. `MetadataCodec.read` keeps its contract; the new reader calls it first. Rationale: the codec writes our format and must keep rejecting unknown schema versions; foreign tolerance belongs elsewhere.
- KTD2. **Our own chunk wins over `parameters`.** Our images carry both, and the JSON is lossless. A newer `schema_version` throws `unsupportedSchemaVersion`; the reader falls back to the `parameters` text and the banner says the image is from a newer app version (consistent with D12).
- KTD3. **Model match is name-based and conservative.** A1111 `Model:` is a checkpoint name, not our id, and `Model hash` is omitted (D22). Match on exact id, then case-insensitive last path component; ambiguity means not installed. (session-settled: user-approved — chosen over fuzzy or display-name matching: a wrong silent match would apply foreign settings to the wrong model.)
- KTD4. **Size snaps by aspect ratio, not to the default.** `ModelSelection.fit` resets an off-grid size to the family default, which would discard the aspect ratio R6 must keep. A new pure helper picks the preset whose aspect ratio is closest in log space, ties broken toward the family default's area. It serves both branches and runs before `fit`, so `fit` sees an on-grid size and only handles steps and guidance. In the not-installed branch the helper runs against the currently selected family.
- KTD5. **Shared apply path.** `reuseSettings(of:)` (`AppModel.swift:599`) is split so its full-apply half takes `ImageSettings`. The drop uses that half for `.mlxCreate` data in the installed case; `.a1111` and `.exif` data go through a dedicated mapper in `AppModel+DropRestore.swift`, never a fabricated `ImageSettings`. The gallery action keeps today's behaviour, including its default-size reset.
- KTD6. **Missing-model state is a new `dropNotice`, not `lastError`.** `lastError` renders red in the generation panel and is cleared by Generate; a warning on the canvas needs its own state with a level (`warning`, `info`).
- KTD7. **File read is bounded and off the main actor.** Cap 64 MiB, read with `Data(contentsOf:options:.mappedIfSafe)` in a detached task. Mirror `LoRADrop.handle` for the `NSItemProvider` plumbing.
- KTD8. **No decision is added to the engine or catalog.** App-side only; no `engine.lock` change.

## Implementation Units

- U1. **HLD D38.** Add D38 to the decision log: drop-to-restore, the installed / not-installed rule, name-based matching, out-of-range seed handling. Amend §8.9's Read bullet to match and mark hash lookup deferred. Per AGENTS.md this lands before code.
  - Files: `docs/HLD.md`.
  - Verification: D38 reads consistently with R4-R7.

- U2. **Generation-data reader.** `ImageGenerationData`, `ImageReadResult` (KTD1) and `ImageGenerationReader.read(from: Data) throws -> ImageReadResult`. Includes a quote- and bracket-aware tokenizer for the A1111 settings line (values such as `Lora hashes: "a: h1, b: h2"` and `Civitai resources: [{…}]` contain commas), multi-line prompt and negative prompt, `<lora:name:weight>` extraction, pairing and stripping (R2, R3), and EXIF `UserComment` for JPEG/WebP through ImageIO. Detects `prompt`/`workflow` PNG chunks and returns `.comfyUI`.
  - Files: `Sources/MCLibrary/ImageGenerationData.swift`, `Sources/MCLibrary/ImageGenerationReader.swift`.
  - Execution note: A1111 writes `UserComment` as UTF-16 behind an `UNICODE\0` prefix and ImageIO may not decode it as a string. Probe a real JPEG and a real WebP first. If ImageIO fails, read the EXIF bytes directly, which means an APP1 parser for JPEG and a RIFF `EXIF` chunk parser for WebP; size the unit for that.
  - Tests: `Tests/MCLibraryTests/ImageGenerationReaderTests.swift`. Cases: our own image (round trip through `MetadataCodec.embed`), newer schema falls back to `parameters` (R2a), plain A1111, multi-line negative, quoted `Lora hashes`, tags stripped and paired by name, stripped file returns `.none`, ComfyUI chunk returns `.comfyUI`, JPEG with EXIF comment, truncated and non-image bytes.

- U3. **Apply rules.** `AppModel+DropRestore.swift`: `restoreFromDroppedImage(url:)`, model matching (KTD3), the aspect snapper (KTD4, pure and unit-testable beside `ModelSelection`), the foreign mapper and the `reuseSettings` split (KTD5), the installed and not-installed branches (R5-R8), a prefix-aware LoRA matcher for AutoV2 hashes (R8), and `dropNotice` state (KTD6).
  - Files: `Sources/MCApp/AppModel+DropRestore.swift`, `Sources/MCApp/AppModel.swift` (split `reuseSettings`, add `dropNotice`), `Sources/MCApp/Model/ModelSelection.swift` (aspect helper).
  - Tests: `Tests/MCAppTests/DropRestoreTests.swift` on `AppHarness` (call `await model.start()` first). Cases: own image with installed model restores everything including LoRAs; same image with the model uninstalled applies only the four fields and sets a warning; foreign image naming an installed model applies steps and CFG, with a fixed-step family sending none; foreign image naming an unknown model; image with no model name; two models matching a name; no selectable model (`.noModels`) stores the raw size and warns; seed 2^40 and -1 leave the seed policy; off-grid size snaps by aspect in both branches; foreign 10-character LoRA hash matches a library entry and an unmatched one is named in `loraNotice`; newer-schema fallback message; no-data and ComfyUI messages change nothing.

- U4. **Canvas drop target and banner.** `.onDrop(of: [.fileURL])` and the banner overlay attach to the outer `CanvasView` container so they wrap all four `canvasMode` branches (R10). Includes a highlight overlay, a banner view bound to `dropNotice`, first-file handling (R13), and clearing on Generate. Existing `.onDrop` on the generation panel (`GenerationPanel.swift:39`) stays.
  - Files: `Sources/MCApp/CanvasView.swift`, `Sources/MCApp/DropRestoreBanner.swift`, `Sources/MCApp/AppModel.swift` (clear on successful Generate).
  - Verification: GUI behaviour is not covered by tests. Build with `xcodebuild`, then drop three files into the running app: one own image, one foreign PNG with an installed model name, one foreign PNG without. Observe the composer values and the banner text.

- U5. **Docs.** If the EXIF probe in U2 finds a non-obvious ImageIO behaviour, record it once under `docs/solutions/integration-issues/`. Update HLD §10 only if the shipped drop behaviour differs from D38.

## Verification Contract

- `swift test` passes, including the new reader and drop suites.
- `xcodebuild` Debug build passes.
- Smoke in the running app with real files: a PNG made by this app, a Civitai PNG, and a Civitai JPEG or WebP. For each, observe prompt, size, model chip and banner.

## Open Questions

- Which real Civitai samples become recorded fixtures (a PNG and a JPEG/WebP). They must be small and carry no content that conflicts with repo hygiene; settle at U2.
- Whether ImageIO decodes A1111's UTF-16 `UserComment` (U2 execution note). It decides only the mechanism, not the behaviour.

## Risks

- Civitai often serves re-encoded WebP with metadata stripped; users will hit the no-data message often, so its wording matters (R11).
- Name matching can fail for models renamed on disk; the warning names the unmatched string so the cause is visible.
- Drop-target conflicts: SwiftUI `onDrop` on the canvas must not swallow the gallery's internal selection gestures. Verify in U4's smoke run.
