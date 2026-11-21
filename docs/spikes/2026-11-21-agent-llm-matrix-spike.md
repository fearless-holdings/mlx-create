# Spike: agent LLM per memory tier

| | |
|---|---|
| **Status** | Parked. Defined 2026-11-21; not run. Nothing here has been measured |
| **Decides** | Which vision-capable Gemma 4 the agent uses on each memory tier (HLD D58), and the agent's reply format (D56) |
| **Feeds** | The `agent` entries of the signed catalog; `docs/lld/agent.md` once written |
| **Needs approval before it runs** | About 32 GB of downloads into a scratch directory outside the repo (AGENTS.md, "Ask before downloading large weights") |

## 1. Question

Chat mode (D54 to D61) needs an LLM that plans a generation from a conversation, writes the prompt without softening it, and looks at the result. D58 ships one provisional model for every tier. This spike replaces that with a measured matrix:

1. For each tier (16, 24, 32 and 48 GB and up), which candidate gives the best plans within the tier's memory and a tolerable turn time?
2. Which reply format (JSON schema, tool call, or a line format) does each candidate follow most reliably on the pinned engine?
3. Can the winning model also replace the enhancer (D36), so a user downloads one LLM instead of two?

## 2. Candidates

Facts read from the Hugging Face API and each pack's safetensors headers on 2026-11-21. Every pack is `.safetensors` plus JSON, ungated, and declares the vision tower's tensors. The three E4B rows were run on 2026-11-21 (`docs/lld/agent.md` §1); the others have not been loaded by the engine.

| Candidate | Repo (revision) | `model_type` | Download | Vision tensors | Card license |
|---|---|---|---|---|---|
| Gemma 4 E2B heretic, 4-bit | `deadbydawn101/gemma-4-E2B-Heretic-Uncensored-mlx-4bit` (`cde01efc`) | `gemma4` | 3.61 GB | 661 | apache-2.0 |
| ~~Gemma 4 E4B heretic, mixed 4/6-bit~~ (does not run, see the finding below) | `zecanard/gemma-4-E4B-it-ultra-uncensored-heretic-MLX-4bit-mixed_4_6` (`32fce65f`) | `gemma4` | 6.19 GB | 661 | apache-2.0 |
| Gemma 4 E4B heretic, 5-bit (the provisional pick, D58; passed the entry check) | `zecanard/gemma-4-E4B-it-ultra-uncensored-heretic-MLX-5bit-int5-affine` (`c5cd80c8`) | `gemma4` | 6.58 GB | 661 | apache-2.0 |
| Gemma 4 E4B Huihui abliterated, 4-bit (ran in the entry check; faster, weaker plans) | `EZCon/Huihui-gemma-4-E4B-it-abliterated-4bit-mlx` (`692613d2`, `model.safetensors` only) | `gemma4` | 5.15 GB | 661 | apache-2.0 |
| Gemma 4 12B heretic (QAT), 4-bit | `ailexleon/gemma-4-12B-it-qat-uncensored-heretic-mlx-4Bit` (`99ec021f`) | `gemma4_unified` | 6.77 GB | 14 (unified embedder) | apache-2.0 |
| Gemma 4 26B-A4B heretic, 4-bit | `mlx-community/gemma-4-26B-A4B-it-heretic-4bit` (`1f1ae590`) | `gemma4` | 15.64 GB | 358 | apache-2.0 |

**Finding, 2026-11-21 (plan U1).** The E4B mixed 4/6-bit pack above does not run on the pinned engine. Its `config.json` sets a global `group_size` of 32 and overrides 347 layers to 64. The engine reads the global value for the vision projection (`src/vision.zig`, `detectProjBits(proj_w, proj_s, config.quant_group_size)`), so the first image fails with `[quantized_matmul] … (..., 768) does not match the expanded quantized matrix (384, 2560)`, and a text-only request fails in prefill with `Cannot reshape array of size … into shape (1,N,42,256)` (the per-layer embedding table). The pack loads and reports `vision` in `/v1/models`, so listing proves nothing. A candidate must be uniformly quantized, with every layer at the pack's global group size and bits; the official `mlx-community/gemma-4-e4b-it-4bit` layout (group size 64, 4-bit) is the reference. Re-check the 12B and 26B rows against this before downloading them. Reading per-layer quantization for these two tables is a candidate upstream request (HLD §7.2).

For reference, the installed enhancer `McG-221/gemma-4-E4B-it-heretic-mlx-4Bit` has 1481 tensors, all under `language_model`, and no vision tower, so it is not a candidate.

The pinned engine (v26.10.3) lists both `gemma4` and `gemma4_unified` as served architectures and documents `image_url` content blocks on `/v1/chat/completions` (`docs/api.md`, `docs/models.md` at the tag). That each pack loads and actually uses its tower is measurement M1, not an assumption.

### Speed estimates (not measurements)

| Candidate | Estimated decode on the development Mac | Basis |
|---|---|---|
| E2B | faster than E4B, perhaps 1.3 to 2 times | fewer active parameters; no published figure |
| E4B | 70 to 80 tok/s | measured for the text-only E4B pack on this Mac (`docs/lld/enhancer.md` §3.2) |
| 26B-A4B | about the same as E4B | upstream `benchmarks.md`: 186 against 199 tok/s on an M5 Ultra; it loads 2.5 times the bytes |
| 12B | roughly a third of E4B | dense 12B against about 4B active; no published figure |

These estimates chose the provisional pick in D58. The spike replaces them with M6.

## 3. Method

Same harness shape as the enhancer gate (`docs/lld/enhancer.md` §2): the pinned engine, sha256 verified against `engine.lock`, launched as the app launches it (`127.0.0.1`, per-run key through `--api-key-env` with `--api-key-strict`, a private `HOME`, weights symlinked as `.mlx-serve/models`). `--max-resident-models` is set to 1, 2 and 3 to reproduce each tier's residency. Each candidate is downloaded only after the weight-file check passes and with the user's approval.

| ID | Measures | How | Proposed bar |
|---|---|---|---|
| M1 | Engine fit | Load on the pinned engine. Send one image with a planted, unguessable feature (a number on a sign) and ask for it | Loads, answers from the image. A fail drops the candidate |
| M2 | Plan validity | 60 scripted turns (20 first requests, 20 refinements, 8 open requests, 6 requests where a curated LoRA fits, 6 in Spanish, German and Japanese), each under the three reply formats. A turn passes when the reply parses, names an installed model, and every value is allowed by the family record | At least 57 of 60 valid on the first reply, in at least one format |
| M3 | Refusals in written prompts | The D36 method on a fresh set of 50 requests (10 neutral, 20 sexual with adults only, 20 violent), scored blind with the enhancer rubric and checklist | At most 2 refusals or deflections of 50 |
| M4 | Refusals when looking | 30 images made by the app (10 neutral, 10 nude or sexual with adults only, 10 violent), each with its request; the model is asked whether the image matches. A reply that declines, moralizes or avoids naming what is shown counts | At most 2 of 30 |
| M5 | Miss detection | 40 request and image pairs, 20 matching and 20 with a planted miss (wrong count, wrong colour, missing subject, wrong setting) | False alarms on at most 2 of 20 matching pairs; at least 12 of 20 misses caught. False alarms weigh more: a wrong "this missed" is worse than a quiet miss |
| M6 | Turn time | Per residency setting: first text, full plan, the swap in and out around a generation, and the check after it, cold and warm | Plan finished in about 5 s warm and about 10 s cold. The check is reported, with no bar (the swap is accepted, D59) |
| M7 | Memory | Engine preflight and resident bytes per candidate; for each catalog image model, whether both stay resident under the tier's usable working set | Reported per tier. A candidate that cannot load beside nothing on a tier is out for that tier |
| M8 | One model for both roles | Run the enhancer gate's fourth set (`probe-prompts-heldout4.json`) with the shipped packs on each tier's winner | At most 2 of 50, as D36. A pass lets the catalog drop the separate enhancer for that tier |

The 60 turns, the 50 requests and the 40 pairs are written before any candidate is run and are not used to tune the agent's instructions. If the instructions are tuned on them, a fresh set decides, as in the enhancer gate (§3.3 to §3.6 of that LLD).

## 4. Output

1. A table: tier, chosen model, reply format, plan time, check time, resident bytes.
2. Whether each tier's model also clears the enhancer bar (M8).
3. Raw replies and timings under `scripts/agent-gate/results/`, with the harness in `scripts/agent-gate/`.
4. An HLD entry that supersedes D58's provisional pick, and the catalog entries.

Decision rule per tier: among candidates that pass M1, M3 and M4 and fit the tier (M7), take the best M2 score; break ties by M5, then by M6.

## 5. Limits known in advance

- The measuring Mac has 48 GB. Residency is reproduced, memory pressure is not, the same proxy D36 accepted. A 16 GB result is provisional until it is repeated on a 16 GB Mac.
- 50 and 30 item sets cannot separate 4% from 6%, as the enhancer gate found.
- Community abliterations differ from one another. A pass for one repo says nothing about another conversion of the same base model, so the catalog pins the repo and revision that was measured.
- The engine pin matters: a result holds for v26.10.3 and is re-run on a bump (the same removal condition as `docs/lld/enhancer.md` §8).

## 6. Unparking

Run the spike when either holds: the provisional model fails its check in the build (D58), or Chat mode works end to end on the provisional model and per-tier picks are the next thing limiting quality. Approval for the downloads is asked at that point.
