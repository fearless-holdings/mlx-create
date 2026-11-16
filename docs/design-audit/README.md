# mlx-create design audit (2026-10-30)

An audit of the UX, the UI and the usage flows of the native app on `main` at commit `633e737`, judged against `STRATEGY.md`: **"nothing to learn"**, and the metric **time to first kept image**. Every finding is a spec in `specs/`, written so that an agent with no other context can execute it. **No app code was changed by the audit itself**; fixes since then are tracked under [Progress](#progress). The deliverable is this file, `specs/*.md` (28 findings), `capture-kit.md` (the tools that made the evidence, which the specs' checks reuse), and `screens/` (86 screenshots plus four accessibility-tree dumps).

The user's brief shaped the bar. They chose mlx-create over Draw Things because Draw Things keeps every rarely used control on screen, feels crowded, and does not feel like a Mac app. So Draw Things is used here as the **counter-example**, and Apple's own apps (Image Playground, Photos) as the model.

## Progress

**26 of 28 done, 0 in progress, 0 deferred, 0 blocked, 2 open.** Last updated 2026-11-10. Findings, evidence and line references describe `633e737`; they are not rewritten as the code moves. Progress lives in two places only:

- the **Status** column in [§2](#2-all-findings), which is the tracker;
- a **Resolution** section at the end of a spec once it ships: the PR and commits, where the result differs from the spec, and what was and was not exercised.

Status values: `open`, `in progress (PR #n)`, `done (PR #n)`, `deferred (reason)`, `blocked (reason)`.

When you ship a finding: update its row, add its Resolution section, and put `Audit: <ID>` in the PR body and in the commit message trailer, so `git log --grep='Audit: '` can rebuild the table. Bump the count and date above.

## Contents

1. [Top 10 findings](#1-top-10-findings-ranked-by-impact-on-time-to-first-kept-image)
2. [All findings](#2-all-findings)
3. [Recommended execution order](#3-recommended-execution-order)
4. [Walkthroughs: steps before and after](#4-cognitive-walkthroughs-step-counts-before-and-after)
5. [Controls visible at rest](#5-controls-visible-at-rest)
6. [Comparable apps](#6-comparable-apps)
7. [Accessibility](#7-accessibility)
8. [Design tokens](#8-design-tokens)
9. [Looked at and judged fine](#9-looked-at-and-judged-fine)
10. [HLD inconsistencies and open items](#10-hld-inconsistencies-and-open-items-not-specced)
11. [Method, environment, and what was not done](#11-method-environment-and-what-was-not-done)
12. [Verification status](#12-verification-status)
13. [Smoke contract every spec must keep](#13-smoke-contract-every-spec-must-keep)

## 1. Top 10 findings, ranked by impact on time to first kept image

| Rank | Spec | Finding | Why it ranks here |
|---|---|---|---|
| 1 | [S01](specs/S01-first-run-single-primary-action.md) | First launch shows three equal grey buttons (Install, Browse models, Get the prompt enhancer) and no primary action | It is the first minute of every buyer's life with the app |
| 2 | [I01](specs/I01-install-progress-visible.md) | A download started from the model browser vanishes from the main window; there is never a time-left estimate | 5–20 minutes of "No image models installed" with no sign of progress, on the path to the first image |
| 3 | [I03](specs/I03-out-of-memory-recovery.md) | Out-of-memory failures appear only as a truncated 10 pt grey cell, with Retry hidden in a right-click menu and advice the app gives no way to follow | Failed generation rate is a stated metric, and 16 GB Macs hit this |
| 4 | [I02](specs/I02-canvas-follows-generation.md) | Generate blanks the canvas ("Select an image…, or generate one."), and only the first image of a batch ever reaches it | Users judge each result where they are looking; this sits on every generation |
| 5 | [S02](specs/S02-composer-progressive-disclosure.md) | Seed policy, a 1–100 Steps stepper and duplicated headers sit always on screen; at 1100×640 the prompt is squeezed to 108 pt and the panel scrolls | The exact Draw Things pattern the user rejects; every session |
| 6 | [S06](specs/S06-canvas-image-bar.md) | The canvas image has no prompt, facts or actions; Export and Reuse hide in the thumbnail's hover or right-click menu | "Kept" means exported or built on, and both are hidden |
| 7 | [I12](specs/I12-generate-disabled-reason.md) | Generate is disabled with no reason (and looks enabled in dark mode) | First launch invites typing into a prompt that cannot generate |
| 8 | [I05](specs/I05-queue-strip-legible-cells.md) | Queue cells carry no prompt, so they all look alike; failed and cancelled cells pile up forever; the header says "Queue empty" above them | Batches and retries are how users get to a keeper |
| 9 | [I06](specs/I06-engine-failure-banner.md) | When the engine dies, the screen offers both "Restart engine" and a "Resume" that fails | The only recovery path when macOS kills the engine for memory |
| 10 | [I10](specs/I10-license-sheet-single-action.md) | Model licence acceptance needs a checkbox and a button; the three licence sheets work three different ways | On the first-run path, before the download |

## 2. All findings

The order is STRUCTURE, then INTERACTION, then VISUAL, as requested. Severity follows Nielsen: 0 not a problem, 1 cosmetic, 2 minor, 3 major, 4 catastrophe. Frequency is how often a user meets the finding. Sizes: S ≈ under 2 h, M ≈ half a day, L ≈ a day or more.

| ID | Status | Title | Tag | Sev. | Frequency | Task | Size | Depends on | HLD change first? |
|---|---|---|---|---|---|---|---|---|---|
| [S01](specs/S01-first-run-single-primary-action.md) | done ([#26](https://github.com/fearless-holdings/mlx-create/pull/26)) | First launch: one primary action | STRUCTURE | 4 | First minute, every user | a | S | — | No |
| [S02](specs/S02-composer-progressive-disclosure.md) | done ([#36](https://github.com/fearless-holdings/mlx-create/pull/36)) | Composer: rarely used settings behind "More options" | STRUCTURE | 3 | Every session | a, b | M | — | No (stays inline, D33) |
| [S03](specs/S03-model-chip-in-toolbar.md) | done ([#35](https://github.com/fearless-holdings/mlx-create/pull/35)) | Model chip in the toolbar, exact model name | STRUCTURE | 2 | Every session | a, b | S | — | No (follows §10) |
| [S04](specs/S04-collection-as-window-title.md) | done ([#35](https://github.com/fearless-holdings/mlx-create/pull/35)) | The window title is the collection, with its menu | STRUCTURE | 2 | Every switch | f | S | — | No |
| [S05](specs/S05-menu-bar-commands-single-window.md) | done ([#34](https://github.com/fearless-holdings/mlx-create/pull/34)) | Commands in the menu bar; single window | STRUCTURE | 3 | Every session | b, c, e | M | — | No |
| [S06](specs/S06-canvas-image-bar.md) | done ([#28](https://github.com/fearless-holdings/mlx-create/pull/28)) | Canvas shows the image's prompt, facts and actions | STRUCTURE | 3 | Every kept image | a, b, c | M | — | No |
| [S07](specs/S07-lora-sheet-entry-and-order.md) | done ([#39](https://github.com/fearless-holdings/mlx-create/pull/39)) | LoRAs: one entry point; opens on the curated list | STRUCTURE | 3 | Every LoRA add | d | S | — | No (wording only) |
| [S08](specs/S08-civitai-download-adds-to-stack.md) | done ([#40](https://github.com/fearless-holdings/mlx-create/pull/40)) | A Civitai download goes on the stack | STRUCTURE | 3 | Every Civitai LoRA | d | M | S07 | Yes: D51, approved 2026-11-05 |
| [S09](specs/S09-gallery-mode-decision.md) | done ([#41](https://github.com/fearless-holdings/mlx-create/pull/41)) | Gallery mode: a view mode of the main window | STRUCTURE | 2 | Finding old images | c | L | S05, I08 | Yes: D52, approved 2026-11-05 |
| [I01](specs/I01-install-progress-visible.md) | done ([#26](https://github.com/fearless-holdings/mlx-create/pull/26)) | Download progress and time left in the main window | INTERACTION | 4 | Every download | a | M | S01 | No |
| [I02](specs/I02-canvas-follows-generation.md) | done ([#27](https://github.com/fearless-holdings/mlx-create/pull/27)) | Canvas keeps the last image; shows every new one | INTERACTION | 3 | Every generation | a, b | M | — | No |
| [I03](specs/I03-out-of-memory-recovery.md) | done ([#27](https://github.com/fearless-holdings/mlx-create/pull/27)) | Out of memory: failure card with Try Again; right copy | INTERACTION | 4 | When memory is short | e | M | I02 | No |
| [I04](specs/I04-lora-rejection-recovery.md) | done ([#32](https://github.com/fearless-holdings/mlx-create/pull/32)) | LoRA rejected: no internal ids; one-click fix | INTERACTION | 3 | Rare | e | S | I03 | No |
| [I05](specs/I05-queue-strip-legible-cells.md) | done ([#32](https://github.com/fearless-holdings/mlx-create/pull/32)) | Queue cells you can tell apart; Clear | INTERACTION | 3 | Batches, failures | b, e | M | I02 | No |
| [I06](specs/I06-engine-failure-banner.md) | done ([#44](https://github.com/fearless-holdings/mlx-create/pull/44)) | Engine failure: one recovery action | INTERACTION | 2 | Rare | e | S | — | No |
| [I07](specs/I07-prompt-tab-key-trap.md) | done ([#25](https://github.com/fearless-holdings/mlx-create/pull/25)) | Prompt: Tab moves focus (keyboard trap) | INTERACTION | 3 | Every keyboard user | all | S | — | No |
| [I08](specs/I08-gallery-keyboard-and-labels.md) | done ([#31](https://github.com/fearless-holdings/mlx-create/pull/31)) | Gallery arrow keys; distinct tile labels | INTERACTION | 2 | Batch review | b, c | S | — | No |
| [I09](specs/I09-enhance-card-actions-and-provenance.md) | done ([#30](https://github.com/fearless-holdings/mlx-create/pull/30)) | Enhance: clear labels, Restore, no stale provenance | INTERACTION | 2 | Every Enhance | b | S | — | No (§8.8 wording) |
| [I10](specs/I10-license-sheet-single-action.md) | done ([#26](https://github.com/fearless-holdings/mlx-create/pull/26)) | Licence sheets: one "Accept and Download" | INTERACTION | 2 | Every download | a, d | S | — | No (see spec on the legal read) |
| [I11](specs/I11-interrupted-download-size.md) | done ([#25](https://github.com/fearless-holdings/mlx-create/pull/25)) | Interrupted download reports real bytes | INTERACTION | 2 | Cancelled downloads | a | S | — | No |
| [I12](specs/I12-generate-disabled-reason.md) | done ([#26](https://github.com/fearless-holdings/mlx-create/pull/26)) | Generate says why it is disabled | INTERACTION | 2 | First launch, empty prompt | a | S | (I01) | No |
| [I13](specs/I13-empty-state-copy.md) | done ([#25](https://github.com/fearless-holdings/mlx-create/pull/25)) | Empty states that match the state | INTERACTION | 1 | First run | a, f | S | — | No |
| [V01](specs/V01-design-tokens.md) | done ([#43](https://github.com/fearless-holdings/mlx-create/pull/43)) | One design-token file (with inventory and migration list) | VISUAL | 2 | Every screen | all | M | see §3 | No |
| [V02](specs/V02-text-contrast-and-status-colour.md) | done ([#45](https://github.com/fearless-holdings/mlx-create/pull/45)) | Status and error text ≥ 4.5:1; colour on symbols only | VISUAL | 2 | Every error | e, d | M | V01 | No |
| [V03](specs/V03-number-formatting.md) | done ([#23](https://github.com/fearless-holdings/mlx-create/pull/23)) | "1024 × 1024", not "1.024 × 1.024"; one decimal style | VISUAL | 2 | Every session (EU locales) | a, b | S | — | No |
| [V04](specs/V04-gallery-column-layout-bug.md) | done ([#21](https://github.com/fearless-holdings/mlx-create/pull/21)) | Gallery shows one column after launch | VISUAL | 2 | Every launch | c | S | — | No |
| [V05](specs/V05-badges-and-redundant-labels.md) | open | One badge style; no label that repeats its button | VISUAL | 2 | Browser, LoRA sheet | a, d | M | V01, S01, S03 | No |
| [V06](specs/V06-sheet-consistency.md) | open | Sheets: one title style, one inset, two widths | VISUAL | 1 | Every sheet | a, d, f | S | V01, I10, S04 | No |

The two decisions the audit needed were approved on 2026-11-05 and recorded in the HLD decision log: **D51** (S08, a finished Civitai download goes on the stack) and **D52** (S09, Gallery as a view mode of the main window).

## 3. Recommended execution order

1. **No-regret fixes.** Small, independent, and needing no structure decision:
   - [x] V04, the gallery column bug;
   - [x] V03, number formatting;
   - [x] I11, the interrupted size;
   - [x] I07, the Tab key trap;
   - [x] I13, empty-state copy;
   - [x] I06, the engine banner (live acceptance 2026-11-06, see §2).
2. **First-run path** (done, [#26](https://github.com/fearless-holdings/mlx-create/pull/26)):
   - [x] S01;
   - [x] I01;
   - [x] I10;
   - [x] I12.

   This is the shortest path to moving time to first kept image.
3. **Window structure:** S05 (menus, single window) → S04 (title) → S03 (chip to toolbar) → S02 (composer). Do S02 after S03 so the at-rest count lands at its target.
4. **Results and recovery** (done, [#27](https://github.com/fearless-holdings/mlx-create/pull/27), [#28](https://github.com/fearless-holdings/mlx-create/pull/28), [#30](https://github.com/fearless-holdings/mlx-create/pull/30), [#31](https://github.com/fearless-holdings/mlx-create/pull/31), [#32](https://github.com/fearless-holdings/mlx-create/pull/32)):
   - [x] I02, S06 and I03;
   - [x] I04 and I05;
   - [x] I08 and I09.
5. **LoRAs** (done, [#39](https://github.com/fearless-holdings/mlx-create/pull/39), [#40](https://github.com/fearless-holdings/mlx-create/pull/40)): S07, then S08 under D51.
6. **Gallery** (done, [#41](https://github.com/fearless-holdings/mlx-create/pull/41)): S09 under D52.
7. **Visual layer:** V01 tokens (done, [#43](https://github.com/fearless-holdings/mlx-create/pull/43)) → V02 (done, [#45](https://github.com/fearless-holdings/mlx-create/pull/45)) → V05 → V06.

**VISUAL work that must wait for STRUCTURE.**

- V01's token file can be created at any time. Migrating `GenerationPanel`, `ModelChip`, `CanvasView`, `QueueStripView`, `EmptyModelsView` and `LoRASection` must wait for S01, S02, S03, S06, I02, I03 and I05, which rewrite most of those lines. Sheets and `GalleryView` can migrate at once.
- V02 waits for I03, I05 and I06, which rewrite the failure, queue and banner text.
- V05 waits for S01 and S03.
- V06 waits for I10 and S04.
- V03 and V04 are bugs and do not wait.

## 4. Cognitive walkthroughs: step counts before and after

Counted on the real app (1100×640 content, FLUX.2 klein 4B, or an empty library for task a). "Clicks" counts presses, including menu choices; typing and waiting are not counted. "Decisions" are choices the user must make. "To learn" are things the user must discover or remember that the screen does not tell them.

| Task | Now: clicks / decisions / to learn | Proposed: clicks / decisions / to learn | Specs |
|---|---|---|---|
| (a) First launch → first kept image | 8 / 3 / 4 | 6 / 2 / 0 | S01, I01, I10, I12, I02, S06, S02 |
| (b) Tweak the prompt, generate again | 2 + 1 per image compared / 0 / 2 | 2 / 0 / 0 | I02, I08, S06 |
| (c) Find and reuse an old image | 5 / 0 / 2 | 4 / 0 / 0 | S06, S05, I08, (S09) |
| (d1) Add a curated LoRA | 6 + scroll / 2 / 1 | 4 / 1 / 0 | S02, S07, I10 |
| (d2) Add a LoRA from Civitai | 7 + scroll / 2 / 2 | 5 / 1 / 0 | S07, S08 (HLD), I10 |
| (e1) Recover from out of memory | 2 / 1 / 3 | 1 / 1 / 0 | I03, I05 |
| (e2) Recover after macOS killed the engine | 1, plus a dead Resume / 1 / 1 | 1 / 0 / 0 | I06 |
| (e3) Recover from a LoRA mismatch | 3 + scroll / 1 / 2 | 2 / 0 / 0 | I04 |
| (f) Change collection | 2 / 1 / 1 | 2 / 1 / 0 | S04 |

### (a) First launch to first kept image

Now (`screens/01-*`, `05b-*`, `02-*`, `03b-*`, `03c-*`):

1. Read the "No image models installed" canvas and choose between three equal buttons: Install, Browse models, Get the prompt enhancer. *Decision; to learn: Install on the card is the path.*
2. Install on the recommended card (Qwen-Image 2.1 Turbo, 10.55 GB). *Click 1.*
3. Licence sheet: tick "I have read and accept…". *Click 2; decision: accept the research-only licence; to learn: the checkbox gates Install.*
4. Install. *Click 3.*
5. Wait for the download. Progress shows in the card, but only because this model is the recommended one; through Browse models, nothing shows after closing the sheet.
6. Click the prompt and type. *Click 4. To learn: Seed, Size and Steps can be ignored.*
7. Generate, or ⌘↩. *Click 5.*
8. The canvas says "Select an image in the gallery, or generate one." while the job starts, then shows a bare step bar, then the image.
9. To keep it outside the app: hover the thumbnail, then the "…" badge (*click 6*), then Export… (*click 7*), then Save in the panel (*click 8; decision: where*). *To learn: export lives on the thumbnail's hover or right-click menu.*

Proposed:

1. One prominent **Download…** with "Recommended for this Mac · 10.55 GB download" (S01). *Click 1.*
2. **Accept and Download** (I10). *Click 2; decision: accept.*
3. The canvas shows "Downloading … · About 6 min left" (I01). Generate's line says "Waiting for … to download" (I12).
4. Type a prompt and press Generate. *Clicks 3–4.* The left panel no longer scrolls, and seed and steps are folded away (S02).
5. The canvas shows "Starting…", then the image with its prompt and actions (I02, S06).
6. **Export…** under the image (*click 5*), then Save (*click 6; decision: where*).

### (b) Tweak the prompt and generate again

Now: edit the prompt (*click 1*), Generate (*click 2*). The previous image leaves the canvas, and in a batch only the first new image appears. Seeing the others means one click per thumbnail. *To learn: results land in the gallery; to keep a composition, set Fixed and type a seed, or use ⌘R, which nothing on screen mentions.*

Proposed: edit, then ⌘↩. The previous image stays under the step bar, every new image takes the canvas, and ← → step through them (I08). Reuse Settings sits under the image (S06), and ⌘R is in the Image menu (S05).

### (c) Find and reuse an old image

Now: the search field (*click 1*) and typing, or scrolling a two-column strip; the thumbnail (*click 2*); right-click or hover "…" (*click 3*); Reuse all settings (*click 4*); Generate (*click 5*). *To learn: the hidden menu; that Reuse pins the seed.*

Proposed: search, then the thumbnail (or arrow keys), then **Reuse Settings** under the image, then Generate. With S09, ⌘2 gives a full-window grid for large libraries.

### (d) Add a LoRA

Curated, now (`10-*`, `10b-*`, `10c-*`): scroll the panel to LoRAs; Add LoRA… or Library… (two buttons, one sheet) (*click 1*); the sheet opens on an empty "Installed" tab, so find "Shelf" (*click 2; decision; to learn: "Shelf" means curated*); Add to stack (*3*); tick the licence checkbox (*4*); Download and add (*5*); Done (*6*).

Curated, proposed: Add LoRA…, visible without scrolling (*1*); the sheet opens on **Recommended**; Add to stack (*2*); Accept and Download (*3*); Done (*4*).

Civitai, now (`11-*`): scroll; Add LoRA… (*1*); Browse Civitai (*2*); Download (*3*); Accept and download (*4*); wait; Installed tab (*5*); find the row and press Add (*6*); Done (*7*). *To learn: downloads go to the library, not the stack; the tab names.*

Civitai, proposed, after the S08 decision: Add LoRA… (*1*); Civitai (*2*); **Download and Add** (*3*); Accept and Download (*4*); Done (*5*).

### (e) Recover from an error

Out of memory, now (`04c-*`, `08c-*`; real failures caused by other tasks on the Mac):

- The failure is a 96 pt grey cell, "Failed · Not enough free memory to run this model. Clo…", under the header "Queue empty", with a blank canvas. *To learn: failures live in the strip.*
- The advice "close other apps or models" has no in-app control for models, and the app has already unloaded them. *To learn.*
- Right-click the cell (*1*), then Retry (*2*). *To learn: right-click.*

Out of memory, proposed: the canvas shows the failure card with the full plain message (the app has freed its own memory; quit other apps) and **Try Again** (*1*).

Engine killed, now (`07-*`): "Restart engine" (*1*). But the queue header offers "Resume", which fails with an error.

Engine killed, proposed: the banner says what to do, offers **Restart Engine** (*1*), and the header says "Waiting for the image engine".

LoRA mismatch, now (from code; not reproducible on this Mac): a message with a raw engine id. Scroll to LoRAs, expand the row (*1*), Remove from stack (*2*), Generate (*3*).

LoRA mismatch, proposed: **Remove LoRAs from Stack** on the card (*1*), then Generate (*2*).

### (f) Change collection

Now (`16-*`): the "Default ⌄" pill (*1*), then a collection (*2*). The current collection carries no check mark, and the window is titled "mlx-create".

Proposed: the same two clicks on the window title, with a check mark on the current collection, and the title and image count always visible (S04). No clicks saved; the gain is orientation.

## 5. Controls visible at rest

Interactive elements on screen before the user has touched anything. These are counted from the macOS accessibility tree (`screens/ax/*.txt`) for mlx-create, and on published screenshots for the other apps. Window buttons, menus, scroll bars and thumbnails are not counted.

| App and state | Controls | Notes |
|---|---|---|
| mlx-create, empty library (now) | 10 | Six belong to a composer that cannot generate yet (prompt, Recent prompts, disabled Enhance, "No model" chip, batch stepper, disabled Generate); three equal canvas buttons compete |
| mlx-create, model installed, nothing generated (now) | 14 | Prompt, Recent prompts, Enhance, Model chip, 3 seed segments, Size, Steps stepper, Library…, Add LoRA…, batch stepper, Generate, collection menu |
| mlx-create, with images (now) | 16 | Adds Search prompts and Filters |
| mlx-create, model installed (after S02, S03, S07) | 10 | The seed segments and Steps fold into one "More options" button |
| mlx-create, viewing an image (after S06) | 16 | Adds the canvas's four image actions. The grid's actions finally have a visible home |
| Image Playground, macOS 27 (Apple's guide screenshot) | 8 | Sidebar, New, Delete, Share, More, the title's edit pencil, "Describe a change", targeted edit |
| DiffusionBee 1.5.1 (project docs screenshot) | 14 | 5 mode tabs, prompt, Prompt Ideas, Styles, **Options** (every setting), Generate, 4 image and app actions |
| Draw Things 1.20250719.0 (wiki's annotated screenshot) | about 55 | The left column alone shows Model, LoRA, Control, Strength, Seed, Seed Mode and Image Size (four ratio buttons, Small/Normal/Large, width), each with an info button |

The composer target in S02 is ≤ 10 in the left panel, and 8 after S03 and S07.

## 6. Comparable apps

There was no hands-on use of Draw Things or DiffusionBee: you asked for published screenshots only. Image Playground is installed here but does nothing in the EU, so its evidence is Apple's guide. Photos was not opened, to keep your library out of the audit; its evidence is Apple's guide.

| | Draw Things (counter-example) | DiffusionBee 1.5.1 | Image Playground (macOS 27) | Photos (macOS 27) | mlx-create now |
|---|---|---|---|---|---|
| Source | wiki.drawthings.ai/wiki/User_Interface (annotated screenshot, v1.20250719.0); App Store listing | github.com/divamgupta/diffusionbee-stable-diffusion-ui `docs/DOCUMENTATION.md` (screenshot) | support.apple.com Mac User Guide, "Create original images with Image Playground on Mac" (window screenshot) | support.apple.com Photos User Guide, "View photos and videos on Mac" (window screenshot) | `screens/` |
| Layout | Settings column \| canvas with prompt box \| version-history column | Prompt across the top, image centred, history in its own tab | Image centred; gallery in a sidebar you can hide; prompt shown as the title above the image | Sidebar of collections; grid or single photo; title and metadata in the toolbar | Composer \| canvas over the queue \| gallery: the same three-column composition as Draw Things |
| Settings | All visible, grouped under Basic, Advanced and All | All behind one "Options" button | Aspect ratio and style buttons only | n/a | Seed policy, size and steps always visible (S02) |
| Prompt and action | Prompt and Generate together, under the canvas | Prompt and Generate adjacent | "Describe a change" under the image | n/a | Prompt at the top left, Generate at the bottom left |
| Result | On the canvas; history in the right column | On the page with "Save Image" under it | Stays on screen; versions of one idea are grouped | n/a | Canvas blanks during generation; only the first of a batch (I02) |
| Image actions | Toolbar icons above the canvas | "Save Image" under the image | Delete, Share and More at the top right | Share, Favorite, Rotate, Edit in the toolbar | Only in the thumbnail's hover or right-click menu (S06) |
| Collections | Projects menu | n/a | n/a | Sidebar | A pill beside the app-name title (S04) |
| Keyboard | — | — | — | Arrow keys move between photos | Arrows do nothing in the grid (I08) |

What to take from this:

- From Image Playground: keep the image central and the prompt next to the result; put image actions where the image is.
- From Photos: title the window with the current collection, put item actions in reach, and use the arrow keys.
- From DiffusionBee: one place for the options you rarely need.
- From Draw Things: nothing. Its permanent settings column is what S02 removes. Its permanent history column is why S09 asks for a decision on the gallery.

## 7. Accessibility

The tree was read through the macOS Accessibility API: the same tree Accessibility Inspector shows, dumped with `capture-kit.md`'s `ax` tool (`screens/ax/`). Contrast was measured from 1x window captures with `contrast.py`; anti-aliasing can only lower the figure, so true ratios are at least the numbers below.

- **Labels.** Most controls carry labels, and the canvas image is "Selected image: <prompt>". Gaps:
  - Gallery tiles of one batch have identical labels (I08).
  - The New Collection name field has no label (V06).
  - The three zero-size shortcut buttons in `MainWindow.ShortcutButtons` are `accessibilityHidden`, so ⌘R, ⌘E and ⌘. exist for no one who cannot see a menu, and there is none (S05).
  - The splitters report as disabled through accessibility, so panel widths cannot be changed by assistive tech. Not specced: low impact.
- **Focus order.** Tab enters the prompt and never leaves, with default keyboard settings and with Keyboard navigation on. Every press types a tab character into the prompt (I07). ⌃Tab did not leave either. The fix was verified in a scratch app.
- **Keyboard-only operation.**
  - Works: ⌘↩ generate; Delete and ⌘A in the grid; Escape and Return in sheets; ⌥↑/⌥↓ on queue cells.
  - Missing:
    - arrow keys in the grid (I08);
    - menu-bar commands for Enhance, Cancel, Reuse, Export, Pause, Models and LoRAs (S05);
    - reaching anything past the prompt with Tab (I07).
  - Not tested: keyboard use of the model-chip popover rows.
- **Contrast (WCAG AA 4.5:1).**
  - `.red` error text: 3.57:1, and 2.86:1 on the queue cell's `.quaternary` fill.
  - `.secondary` on white: 3.95:1; on `.quaternary`: 3.80:1.
  - The disabled Generate label in light mode: 1.65:1. In dark mode the disabled fill (#095DBA) reads as enabled next to #007AFF.
  - The engine banner: 13.2:1 (light) and 10.4:1 (dark).
  - Fixes: V02, I05 and I12.
- **Not run:**
  - Accessibility Inspector's own audit (a GUI tool not driven from the agent shell);
  - XCUITest's `performAccessibilityAudit()`;
  - a VoiceOver session;
  - Increase Contrast and Reduce Transparency.

  Treat these as open checks. S02 respects Reduce Motion for the one animation it adds.

## 8. Design tokens

[V01](specs/V01-design-tokens.md) carries:

- the inventory: 139 `.font` uses with 16 distinct styles; 85 paddings with 25 distinct values; 101 stack spacings with 10 values; 3 corner radii plus capsules; 48 colour literals with 17 values; 86 `.secondary`;
- where the values diverge (sheet titles, insets and widths; three badge implementations; card fills; red text; 66 uses of 10 pt text);
- the complete `Sources/MCApp/Design/MCTokens.swift`, which type-checks under Swift 6 for macOS 26.2;
- a mapping table;
- every call site at `633e737`, file by file and line by line.

The token values in brief:

- **Spacing:** 2 / 4 / 6 / 8 / 12 / 16 / 20 / 24 (`MCSpacing.hairline` … `.emptyState`).
- **Radii:** 6 (fields and small thumbnails) and 10 (cards, tiles, cells), plus capsules for badges.
- **Strokes:** selection rings 3 pt, field outlines 1 pt.
- **Type:** `.mcSheetTitle` (title2 bold), `.mcRowTitle` (headline), `.mcBody`, `.mcSupporting` (callout, for anything the user must read to act), `.mcMetadata` (caption, for sizes, counts and dates only), `.mcBadge`.
- **Colour:** `MCTone.critical`, `.warning` and `.success` colour symbols, fills and rings, never text. Essential text is `.primary`. `.secondary` is reserved for metadata that repeats something.

## 9. Looked at and judged fine

These were reviewed and deliberately left alone. Most are already Apple-like, or are settled decisions that work.

- **The three-panel split itself (D33).** It stays as the default. The problems are inside the panels (S02, S06) and the gallery's width (S09, which needs your decision), not the split.
- **Per-family controls (D21, §8.3).** No CFG or negative prompt for the turbo families, and fixed steps shown read-only for Qwen Turbo. Correct, and it is the "expert in the box" doing its job.
- **Prompt history (D39).** The clock button with a help tag and a type-to-filter popover, scoped to the collection. Clear and small.
- **Enhance while streaming.** Live text in the card, Cancel available, "Built on earlier text" when stale, and a VoiceOver announcement when ready. Good feedback; only the labels change (I09).
- **Gallery search and filters (D37).** A 200 ms debounce; the "Models (any of)" and "LoRAs (all of)" semantics are spelled out; the header hides until there is something to search.
- **Delete to Trash without confirmation (D37).** Consistent with Finder and Photos (recoverable from the Trash), and the queue guard keeps running jobs safe.
- **NSFW handling (D15).** Hidden until opted in, previews blurred with a per-preview Show, and the missing level treated as NSFW. Correct defaults; nothing to change.
- **Licence notices (D45, D46).** The "Refusal reduction and quality improvement" wording and its placement are an approved decision; untouched.
- **Engine banner contrast and placement.** Above all three panels, ≥ 10:1. Only the copy and the dead Resume change (I06).
- **Calibration header** ("Measuring this Mac's speed…", D48). Honest, passive and short.
- **Launch and loading views.** "Opening library…" is immediate and matches HIG Launching.
- **The minimum window of 1100×640.** Everything critical fits once S02 lands; no reason to change it.
- **Queue reordering.** Context menu, ⌥↑/⌥↓ and named VoiceOver actions. Complete.
- **Dark mode overall.** System colours and materials adapt correctly. The exceptions are the disabled Generate (I12) and red text (V02).
- **Drop-to-restore (D38).** Code reviewed; the banner is dismissible and states what was not applied. Not captured live (it needs a drag).
- **The LoRA weight slider and trigger-word chips.** Hidden in the row's expanded state, which is the right place.

## 10. HLD inconsistencies and open items (not specced)

- **HLD §8.3 lists an "Advanced: always: `cond_gain` / `cond_weights`" row.** That contradicts STRATEGY.md Boundaries ("no Advanced panel") and the AGENTS.md scope guard. The code does not implement it. Recommend deleting the row.
- **HLD §8.3 Steps calls for "quality presets (Fast / Balanced / Quality)".** They are not implemented, and no family record defines their step counts. S02 folds the stepper away instead of inventing values. Needs family data, or a decision to drop presets.
- **The LoRA "Wide range (−20 to 20)" toggle is an expert knob** (STRATEGY.md), but HLD §8.3 specifies it. It is only visible in an expanded row. Consider removing it; that needs an HLD §8.3 change.
- **HLD §10 Onboarding** (hardware scan, starter set, analytics opt-in, first collection) is not a flow in the app. S01 covers the starter-set part only. Analytics waits on a vendor (§15).
- **The empty-canvas enhancer offer** comes from plan items F2/R16. S01 removes it from that screen; update the enhancer plan if you accept S01.
- ~~**AGENTS.md** still says the vertical slice is on branch `feat/t2i-generation-core`; the work is on `main`.~~ Fixed 2026-11-02.

## 11. Method, environment, and what was not done

- **Machine:** macOS 27.2 (26B123), Xcode 27.1, 48 GB Apple Silicon, three displays (captures on a 1x 1920×1200 external display). Build: `xcodegen generate` and `xcodebuild … -derivedDataPath build build` (BUILD SUCCEEDED). The app ran in throwaway homes (`CFFIXED_USER_HOME`): an empty library, and one with FLUX.2 klein 4B and the Gemma enhancer symlinked in. The real `com.fearless.mlx-create` preferences were exported before and imported back after; the real library was not opened.
- **Shared machine.** Other image-generation tasks ran at the same time. They caused every memory refusal seen (engine log: "needs ~5.8 GB free … only 3.8 GB is available"; "needs ~1001MB … ~510MB available"). The audit treats the app's *handling* of those refusals as findings, not their cause.
- **Sizes:** "small" = a 1100×692 window (the 1100×640 content minimum plus the 52 pt toolbar), "large" = 1680×1050. Dark captures flipped the system appearance for a few seconds each; the `-AppleInterfaceStyle` launch argument has no effect on this macOS.
- **Captured** (`screens/`): first launch with an empty library; model downloading (browser and main window) and interrupted; first generation in progress and finished; queue with several jobs; populated gallery; the engine error banner (and restarting); the LoRA library sheet (empty, Shelf, Civitai tab, installed); the model browser and licence sheets; the enhancer flow (install sheet, loading, streaming, ready, accepted, failure); popovers and menus; collections.
  - Only some states have all four variants (small and large, light and dark). These were captured in fewer:
    - interrupted download, licence sheets, enhancer loading and streaming, popovers and menus, the collection sheet: small light (some also small dark);
    - the LoRA stack: large only.
  - A generation in progress at large size and in dark mode is covered by `04-queue-several-jobs_*`. Later attempts at a dedicated capture failed for memory (see `08c-*`).
- **Not captured:**
  - the drop-to-restore banner (needs a drag);
  - a LoRA mismatch (the pre-check prevents it, and no installed LoRA fails only in the engine);
  - the LoRA library detail pane (list row selection could not be driven through accessibility);
  - the recommended-card download (it would have pulled a 10.55 GB model; FLUX.2 klein 4B was downloaded about 438 MB with your consent, then cancelled and deleted).
- **Downloads made:** about 438 MB of FLUX.2 klein 4B (cancelled; throwaway home deleted), and one 92 MB shelf LoRA ("amateur_selfie_4b") in the throwaway home (deleted).
- **Civitai previews** in `screens/11-*` are pixelated before commit: they are third-party images.
- **HIG citations** come from Apple's HIG JSON for The menu bar, Windows, Toolbars, Sidebars, Split views, Sheets, Popovers, Disclosure controls, Progress indicators, Keyboards, Accessibility, Color, Typography, Onboarding, Loading, Feedback, Buttons, Layout and Launching, fetched on 2026-10-30 and quoted in each spec.

## 12. Verification status

- **Spec execution by fresh agents: no trial recorded.** The audit's brief was "we'll take care of the execution afterwards"; the random pick (seed `1793377315`) was **V04**, **I08** and **V01**. All three have since shipped through the normal workflow, not as recorded blind trials. Which specs have shipped is in [Progress](#progress).
- **Static check of all 28 specs, done.** Every repository path a spec names exists, except the 15 new files the specs themselves create. Every type, function and property a spec names exists in the code, unless the spec defines it, it is an accessibility role, or it is an Apple API.
- **Verified by experiment while writing:**
  - I07's Tab and ⇧Tab handler (a scratch SwiftUI app; ⇧Tab arrives as U+0019);
  - V01's token file, which type-checks with `swiftc -swift-version 6` for `arm64-apple-macos26.2`;
  - the capture kit's scripts, which compile and run;
  - I03's memory-refusal strings, read from upstream mlx-serve at the pinned tag `v26.10.3` (`src/server.zig`).
- **Unverified assumptions inside specs, each with an explicit check or fallback:**
  - `toolbarTitleMenu` rendering on macOS (S04 step 4 gives the fallback);
  - ~~the V04 root cause~~ (resolved: traced with temporary logging when V04 shipped; the spec's Evidence records the real cause, which was not the inferred one);
  - `@Entry` on `FocusedValues` (S05, standard SwiftUI).

## 13. Smoke contract every spec must keep

`UITests/MLXCreateUITests` finds the app's controls by these names. A spec that renames any of them must update the tests in the same change. S02, S05, S06 and I07 say exactly how.

- text view **"Prompt"**;
- text field **"Seed"**;
- radio buttons **"Random"**, **"Fixed"**, **"Increment"**;
- a pop-up button whose value contains **"×"**, with menu items containing "×";
- button **"Generate"**;
- labels beginning **"Model: "**, **"Generation progress"**, **"Selected image: "** and **"Image: "**;
- tile menu items **"Reuse prompt"** and **"Reuse all settings"**;
- ⌘R.
