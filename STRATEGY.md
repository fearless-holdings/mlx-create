---
name: mlx-create
last_updated: 2026-10-21
---

# mlx-create Strategy

## Purpose

Uncensored image and video generation costs either money (subscriptions or API credits on the few cloud services that allow it) or expertise (Comfy workflows to wire and tweak, models and LoRAs to match to your hardware), so most people who want it are locked out. On a Mac, running a model is no longer the hard part; getting a great image is.

## Positioning

We democratize it by making it free and easy. You pay once for the app, then generate on the Apple Silicon Mac you already own, with no subscriptions or per-image costs. The expertise is baked in: the app makes the technical calls (model fit, LoRA compatibility, per-family settings), keeps controls minimal, and advises on the prompt instead of handing over a settings panel. A cloud service can't truthfully claim "free to run", and a Comfy-class tool can't claim "nothing to learn".

## Users

**Primary:** The curious Mac owner: has a capable Apple Silicon Mac, wants images that cloud tools refuse, has never run a model. They're hiring mlx-create to make the image in their head, privately, without learning the stack.

## Boundaries

- No expert knobs: no sampler or scheduler pickers, no Advanced panel, nothing the user must understand to get a good image.

_Resist a change when:_ it makes the user learn something to get a good image, or trades result quality for reach or features.

## Key metrics

- **Time to first kept image**: first launch to the first image the user keeps, model download included; opt-in content-free analytics (vendor open, HLD §15).
- **Failed generation rate**: share of jobs ending in OOM, LoRA mismatch or engine error; opt-in analytics, from the job outcome the app already records.
- **Week-4 active generators**: share of buyers still generating in their fourth week; opt-in analytics.
- **Weekly new buyers**: purchases per week; the licensing/payment provider (open, D2).

## Tracks

### Expert in the box

The knowledge an expert would bring, built into the app: per-family enhancer packs and defaults, LoRA fit checks, plain-language errors.

_Why it serves the approach:_ it is the "nothing to learn" half of free and easy.

### Zero to first image

First launch to a kept image on this Mac with no decision the user can't make: catalog, on-device calibration, recommendations that fit the machine, one-click downloads.

_Why it serves the approach:_ easy has to hold from the first minute, or the user never reaches a good result.

### Uncensored quality and supply

Great uncensored output in every family we offer: curated LoRAs, prompt packs tuned per family, families chosen by uncensored quality and LoRA supply. The engine is a means, not a constraint.

_Why it serves the approach:_ free and easy is worthless if the image isn't the one they wanted.

## Brand

**One-liner:** Your Mac. Your images. No limits.

**Key message:** Pay once, generate on the Mac you already own, nothing to learn. Public copy stays neutral, with no NSFW marketing (HLD D3).
