---
title: "Chat Mode: an agent that makes the image - Plan"
type: feat
date: 2026-11-21
execution: code
artifact_contract: ce-unified-plan/v1
product_contract_source: user-interview
---

# Chat Mode: an agent that makes the image - Plan

## Goal Capsule

- **Objective:** A user who has never run a model opens mlx-create, describes a picture in a chat box, and gets a good image, then changes it by talking. No setting is shown or needed.
- **Means:** a vision-capable abliterated Gemma 4 in the bundled engine plans each request; the app validates the plan and runs it through the existing composer, queue and library (HLD D54 to D61).
- **Authority:** `docs/HLD.md` D54 to D61, then this plan. Where the plan and a `D*` entry disagree, stop and ask; do not let code diverge.
- **Execution profile:** one stack with `gh stack` (AGENTS.md, Repo hygiene), nine layers, foundations at the bottom, one concern per layer. Each layer builds, passes `swift test` and leaves the app usable; Chat mode becomes the default only in layer 8.
- **Stop conditions:** stop and ask before any model download (U1's is done — `docs/lld/agent.md` §1); stop if the provisional model fails U1; stop before changing an engine launch flag; stop if a layer needs a decision D54 to D61 do not cover.
- **Finishes the work:** the stack is merged, the real-engine and GUI smokes in the Verification Contract have run on this Mac, and the HLD, `docs/lld/agent.md` and `AGENTS.md` describe what was built.

## Product Contract

### Summary

Chat mode is a view mode of the main window and the default one. The collection's gallery fills the window; a floating chat container sits over it at the bottom. The user types what they want. A local agent picks the model, writes the prompt, picks LoRAs and settings, and queues an ordinary job. The image lands in the gallery. The user refines it in words, and each refinement is a new generation that starts from the earlier image's settings.

### Problem Frame

STRATEGY.md's primary user "has never run a model". Today the first screen is a three-panel workspace with a prompt editor, a model chip, a settings disclosure and a LoRA stack, and a good image depends on knowing which family suits the subject, how that family wants to be prompted and which LoRA helps. The app already holds that knowledge (family records, prompt packs, the curated shelf, fit bands), but the user has to operate it. Chat mode makes the app operate it.

### Requirements

**Window and layout (D54)**

- R1. Chat is the mode on first launch and whenever no mode is stored. View ▸ Chat ⌘1, Canvas ⌘2, Gallery ⌘3. A stored mode wins.
- R2. In Chat mode the gallery fills the window and a chat container floats over it: centred, about 700 pt wide, anchored to the bottom, always visible. It holds the text box and the last two messages.
- R3. A chevron unfurls the history to two thirds of the window height and folds it again. The gallery stays scrollable to its last row behind the folded container.
- R4. Clicking a gallery image shows it large in place of the grid, with the container still on top. Close or Esc returns to the grid.
- R5. Chat mode shows no prompt editor, settings, LoRA stack, queue strip or model chip.
- R6. While an image renders, the agent's pending message shows a status line and a progress bar, and a placeholder tile with progress sits first in the gallery.
- R7. A finished image replaces its placeholder as the first, highlighted tile. It does not open by itself, except that a large view still showing the image it showed when the request was queued switches to the new image (amended 2026-11-22).

**Conversation (D55)**

- R8. Each collection has one conversation, stored on device and restored on relaunch. Switching collection switches conversation.
- R9. The history is text only.
- R10. Clear Conversation removes the messages after a confirmation and keeps every image.

**Agent (D56)**

- R11. Each user message produces one plan: say, ask, propose a download, or generate.
- R12. Every generate plan is validated against the family record and enqueued through `GenerationComposer`. The agent cannot send a value the manual UI could not.
- R13. Nothing technical appears in the chat (model or LoRA names, prompts, seeds, sizes), except on a download card.
- R14. The agent picks the best installed model for each request.
- R15. One image by default, up to four when the user asks for options or the request is open.
- R16. The agent asks at most one question, with suggested answers, and never two in a row.
- R17. The agent replies in the user's language. Prompts are written in English.
- R18. While the agent works, Send becomes Stop (also ⌘.). Stop cancels the LLM reply or the running job. The user can type but not send.
- R32. The agent's text streams into its message as the LLM writes it (session-settled: user-directed, 2026-11-21, over showing the sentence whole).

**Refinement (D57)**

- R19. A change request makes a new text-to-image job that starts from the stored settings of the image the user means.
- R20. That image is, in order: the one shown large, else a single gallery selection, else the newest image the conversation made.
- R21. The agent LLM is shown that image.

**Agent LLM (D58)**

- R22. The agent LLM is a signed-catalog model of kind `agent`, installed through the existing installer with its license accepted (D20).
- R23. No agent code ships on a model that has not passed U1 on this Mac.

**Check (D59)**

- R24. After an image appears, the agent looks at it. On a clear miss it says what is off in one sentence and offers one button that runs the fix.
- R25. The agent never retries silently and never holds an image back.

**Downloads and first launch (D60)**

- R26. A download is proposed on a card with name, size and license and one button. Only signed-catalog image models that fit this Mac and curated shelf LoRAs can be proposed.
- R27. On a first launch with nothing installed, the conversation opens with a greeting and one card for the recommended image model plus the agent LLM. A request typed during the download runs when both are ready.
- R28. A request that was waiting on a download runs when the download ends.

**Adult content (D61)**

- R29. When the plan picks a curated `nsfw` LoRA while the opt-in is off, the image is made without it and a notice offers the switch and Retry. At most once per conversation while the switch is off.
- R30. No prompt or image is classified, filtered or refused by the app.

**Failure**

- R31. Every failure (engine down, out of memory, unreadable plan, LoRA rejected, paused queue) appears as an agent message in plain language with one way forward.

### Key Flows

- F1. First image. The user types a request. Status reads "Thinking…", the agent's sentence streams in, then "Making your image… 3 of 8" with a placeholder tile. The image lands first in the gallery; the agent's message is one sentence. Covered by R2, R6, R7, R11 to R15.
- F2. Refinement. The user clicks the image (it opens large), types "make it night". A new image lands and the large view switches to it; closing the large view shows both in the grid (amended 2026-11-22: it used to keep showing the earlier one). Covered by R4, R19 to R21.
- F3. Open request. "A cool poster" gets one question with three suggested answers; clicking one generates. Covered by R16.
- F4. First launch. Greeting, one card, one click, two downloads with progress in the card; the typed request runs when they finish. Covered by R26 to R28.
- F5. Miss. The agent's follow-up reads "The sign's text came out garbled." with Fix it. Covered by R24, R25.

### Acceptance Examples

- AE1 (R12). Given a plan with a size off the family grid, the queued job carries a grid size.
- AE2 (R16). Given the last agent message was a question, a plan of `ask` is not shown as a second question.
- AE3 (R20). Given an image shown large and a different newest image, a refinement starts from the large image's settings.
- AE4 (R29). Given the opt-in off and a plan naming a curated `nsfw` LoRA, the job has no such LoRA and the result is followed by the notice; a second such turn in the same conversation shows no second notice.
- AE5 (R18). Given a running chat job, Stop cancels it, the placeholder goes, and the message reads as stopped.
- AE6 (R8). Given a conversation and a relaunch, the same messages are shown; given a collection switch, the other collection's messages are shown.
- AE7 (R28). Given a request typed before the agent LLM is installed, the turn starts by itself when the install finishes.

### Scope Boundaries

**Deferred**

- True image edits (`mode:"edit"`) and attached pictures (D57).
- Video (D7: the message table references jobs, so it needs no schema change).
- The per-tier LLM matrix, and one LLM for agent and enhancer (parked spike, D58).
- Remote updates of the agent's family guides (bundled, like the prompt packs, D36).
- A conversation list, search in the conversation, editing a sent message.

**Considered and not built**

- A fallback that generates from the user's raw text when the plan cannot be read. It would hide a broken agent behind mediocre images. An unreadable plan is retried once, then reported (KTD12).
- Checking every image of a multi-image turn. The user asked for options and picks among them; only single-image results are checked (KTD11).
- Writing the user's chat text into the PNG metadata. Export always keeps metadata (D37), so it would leak conversation text into exported files (KTD17).

## Planning Contract

### Key Technical Decisions

Hypotheses are marked. U1 settles them before any layer above layer 1 is written.

- KTD1. **A new module, `MCAgent`, holds the agent's pure logic.** It depends on `MCEngine`, `MCCatalog`, `MCLibrary`, `MCGeneration` and `MCEnhancer`. Three pure steps, each testable without an engine: `AgentContext` → `ChatRequest` (the prompt), reply text → `AgentPlan` (the parser), `AgentPlan` + context → `ResolvedPlan` (validation into a `GenerationDraft`). No protocol is added (AGENTS.md: protocols only at HLD-named seams).
- KTD2. **Hypothesis: the reply is one JSON object, constrained by `response_format` with a JSON schema, and streamed.** Field order is `intent` (one sentence, never shown), `text` (what the agent says to the user), `action`, then the action's fields, so the model states what the user wants before it chooses, and the sentence the user reads arrives before the plan's details. D36's plain-text rule binds the enhancer only (D56). If U1 shows the pinned engine or the model handles the schema badly, the fallback is an unconstrained JSON reply read by a tolerant parser; the parser is written tolerant either way.
- KTD3. **The LLM sees opaque keys, not names.** Models are `m1…`, LoRAs `l1…`, sizes `square`, `landscape`, `portrait`, `wide`, `tall` mapped to the family's `sizePresets` by aspect. A curated LoRA is described by its shelf role and trigger words; a LoRA the user installed is described by its name and trigger words, because nothing else describes it. Keys keep names out of replies by construction where possible (R13).
- KTD4. **Family guidance for the agent is bundled in `Sources/MCAgent/Resources/Guides.json`** (one line per family and one per curated LoRA role). The prompt style comes from the enhancer's packs, read through a new public accessor on `MCEnhancer`; the pack files are not edited, because their text is what the enhancer gate measured (`docs/lld/enhancer.md` §8). The fidelity rule ("keep every explicit detail…") is the enhancer's sentence, exposed as one shared constant.
- KTD5. **The agent's chat calls run inside the existing lease.** `JobExecutor.withEnhancerLease` gains `rewarmsDisplaced: Bool = true`. The agent passes `false`: after a plan the next job loads whichever model the plan chose, so re-warming the displaced one would cost a wasted load (10 to 30 s) whenever the agent switches model. Enhance is unchanged.
- KTD6. **At 24 GiB and above the agent LLM stays resident across generations.** `switchModel` today unloads every other resident model. It gains a set of ids to keep, used only when `memoryTier.maxResidentModels > 1`. U1 showed the engine does not evict an idle chat model to fit a media model; it refuses the load with HTTP 503. So when a load is refused for memory with the LLM kept, the executor unloads the kept ids and tries the load once more.
- KTD7. **Turn orchestration is a `ChatModel`**, `@MainActor @Observable`, owned by `AppModel` as `browser`, `civitai` and `shelf` are. One turn at a time. Phases: idle, thinking, waiting for a download, generating (job id), checking. It talks to `AppModel` through the same store, executor, composer and browser the manual UI uses.
- KTD8. **Messages live in table `chat_message`, migration `v12-chat-message`:** `id` (autoincrement, the order), `collection_id` (cascade), `author` (`user` or `agent`), `kind`, `body` (JSON, a Codable payload per kind), `job_id` (nullable, no foreign key), `created_at`. The migration body lives in a new file, as `createPromptHistoryTable` does.
- KTD9. **`showsGalleryOnly` becomes `windowMode: MainWindowMode` (`chat`, `canvas`, `gallery`).** Stored as a string under the existing key. A stored legacy Boolean maps `true` to `gallery` and `false` to `canvas`; no value means `chat`. `AppModel.swift` is 31.5 KB against a 32 KB file budget, so `live()` and its helpers move to `AppModel+Live.swift` in the same layer, before anything is added.
- KTD10. **Placeholder tiles exist only in Chat mode.** They come from the current collection's queued and running jobs (one tile per image still to make), sit before the images, show progress for the running one, and cannot be selected. D33's "jobs only in the strip" holds in Canvas mode.
- KTD11. **The check runs only for a single-image result**, and is skipped when the user has already sent another message, or the job failed or was stopped. Its reply is a JSON object `{match, issue}`. The instruction asks for clear misses only (missing subject, wrong count, wrong setting, unreadable text that was asked for). Fix it starts an ordinary turn.
- KTD12. **An unreadable or invalid plan is retried once with the error stated, then reported** with Try Again. Nothing is generated from a plan the app could not read.
- KTD13. **Hypothesis: the image is sent to the LLM as a JPEG, longest side 768 px, in a `data:` URL inside an `image_url` part.** The app makes the JPEG with ImageIO; that is image I/O, not inference.
- KTD14. **Context sent per turn:** fixed system text (rules, the options with their keys, the family guides; stable across turns so the engine's prefix cache holds it), the last 12 messages, then the referent's settings and image. A result message is rendered for the LLM with the prompt and keys it used; the user never sees that rendering.
- KTD15. **The download card carries the full license text the sheet carries** (name, version, commercial-use line, summary, link, always-on notices), from a view extracted out of `LicenseSheet`, so D20 and D26 hold with one button. The installer runs one install at a time, so the card queues its items and `ChatModel` starts the next when one ends.
- KTD16. **The adult notice is decided in the resolver.** The LLM is given curated `nsfw` LoRAs whether or not the opt-in is on. With it off, the resolver drops them and sets a flag; nothing reads the prompt or the image (R30).
- KTD17. **Chat jobs leave `originalPrompt` nil** and write nothing chat-specific into the PNG.
- KTD18. **A paused queue is reported, not overridden.** The pending message reads that the queue is paused and offers Resume.
- KTD19. **Catalog:** `CatalogModelKind` gains `agent`; one entry for the U1 model with `ram_gb` from the engine's preflight line; rebuilt and signed with the dev key (sequence 10). A catalog with `agent` does not decode in a build older than this one; no build has shipped, and the production catalog URL is still a release prerequisite.
- KTD21. **The agent's sentence streams out of the JSON reply (R32).** `PlanTextStreamer`, a pure incremental reader in `MCAgent`, takes the reply's deltas and yields the unescaped characters of the top-level `text` string as they arrive, handling escapes and a delta that ends mid-escape; it yields nothing for any other field. The check's reply is ordered `match`, `issue`, and `issue` streams only once `match` has read `false`. A reply that is then retried (KTD12) clears the streamed text. Because `text` is written before the plan is resolved, the instruction asks for a sentence about what the agent is making, never about a model, a download or a result. Hypothesis: the pinned engine streams deltas while a JSON schema constrains the reply; U1 checks it. If it does not, the fallback in KTD2 (unconstrained JSON) streams the same way.
- KTD22. **The agent is told that most pictures need no LoRA, and each LoRA's description says what it is not for.** U1 showed both packs attach LoRAs that do not fit the subject (`docs/lld/agent.md` §1.4). The resolver cannot judge relevance, so it only caps a plan at two LoRAs. The `text` instruction asks for a sentence about what is being made, in the present tense, with no question unless the action is `ask`. Any tuning of the instructions is judged on turns written after U1's, since U1's have been seen.
- KTD20. **Tests follow the AGENTS.md sync rules:** `await model.start()` before `refreshModels()`, `engineHasReceived` before `finishHeld`, projection waits after store waits, `SuspendingClock` deadlines. `FakeEngine.chat` already scripts chat replies by call number.

### What is verified and what is not

**U1 ran on 2026-11-21 (`docs/lld/agent.md` §1).** KTD2, KTD13 and KTD21 are confirmed on the pinned engine; KTD6 is corrected above. The provisional model is `zecanard/gemma-4-E4B-it-ultra-uncensored-heretic-MLX-5bit-int5-affine` at `c5cd80c8`, `ram_gb` 6.10. The pack first chosen (mixed 4/6-bit) does not run on the pinned engine. The bullets below are the state before U1.

- Verified by reading the pinned engine's docs at `v26.10.3`: `/v1/chat/completions` accepts `image_url` parts and `response_format`; `gemma4` and `gemma4_unified` are served.
- Verified from pack headers: the candidate pack declares 661 vision tensors; the installed enhancer has none.
- **Not verified, settled by U1:** that the candidate loads and sees on the pinned engine, the JSON-schema reply (KTD2), the JPEG data URL (KTD13), its preflight `ram_gb`, and that it writes explicit prompts and describes explicit images without refusing.
- **Not verified, settled by the layer 9 smoke:** KTD6's residency on this Mac. No 16 GB or 24 GB Mac is available; `--max-resident-models 1` reproduces residency only (the proxy D36 accepted).

## Implementation Units

### U1. Provisional model check (no layer; before any agent code)

- **Goal:** R23. Settle KTD2, KTD13 and the catalog's `ram_gb`.
- **Owner:** the lead authors the harness, the turns and the pass rule, and reads the results. Not delegated.
- **Needs approval:** downloading `zecanard/gemma-4-E4B-it-ultra-uncensored-heretic-MLX-4bit-mixed_4_6` at `32fce65f` (6.19 GB) into a scratch directory outside the repo.
- **Files:** `scripts/agent-gate/check_provisional.py`, `scripts/agent-gate/turns.json`, `scripts/agent-gate/results/` (modelled on `scripts/enhancer-gate/run_gate.py`: pinned engine verified against `engine.lock`, launched as the app launches it).
- **Checks:**
  1. Weight files are `.safetensors` and JSON only; the engine loads the pack; the preflight line gives `ram_gb`.
  2. Sight: three images made on the installed FLUX.2 klein with planted features (a sign's number, an object count, a colour); the model answers each from the image.
  3. Plans: 12 scripted turns (4 first requests, 4 refinements with a referent, 2 open, 1 in Spanish, 1 where a curated LoRA fits), with the JSON schema and without, streamed. A turn passes when the reply parses and every value is one the context offered. The run records whether deltas arrive while the schema is on and whether `text` precedes `action` (KTD21).
  4. Explicit text: 10 requests (5 sexual with adults only, 5 violent); the written prompt keeps the user's explicit terms.
  5. Explicit sight: 4 app-made images (2 nude adults, 2 violent); the model says whether each matches its request without declining.
  6. Timing: first text and full plan, warm and cold, with `--max-resident-models 1` and 3.
- **Pass rule:** 1 and 2 pass outright; at least 11 of 12 plans valid in one format; no refusal in 4 or 5 (softened wording is reported, not a fail: the D58 ship bar is the spike's M3 and M4, a release prerequisite).
- **On a fail:** stop and return with the numbers and two options: the 12B pack (6.77 GB), or unparking the spike.
- **Output:** a results section in `docs/lld/agent.md`, written in layer 1.

### U2. Decisions and design docs (layer 1, `agent/docs`)

- **Files:** `docs/HLD.md` (G1, §6 module list and diagram, a new §8.11 Agent, §9 `CHAT_MESSAGE`, §10, §11, §12, §13, §15), `docs/lld/agent.md` (new: turn flow, context, plan schema, resolver rules, residency, U1 results), `docs/spikes/2026-11-21-agent-llm-matrix-spike.md`, `AGENTS.md` (non-negotiable 1 names the D61 notice; module list; the Chat smoke command once layer 9 adds it), this plan.
- **Test expectation:** none, documentation only.

### U3. Engine chat surface and lease (layer 2, `agent/engine-chat`)

- **Goal:** the client can send what the agent needs; the lease and model switch behave as KTD5 and KTD6 say.
- **Files:** `Sources/MCEngine/ChatStream.swift` (split if it nears the budget), `Sources/MCGeneration/EnhancerLease.swift`, `Sources/MCGeneration/Executor.swift`, tests in `Tests/MCEngineTests`, `Tests/MCGenerationTests`.
- **Approach:**
  1. `ChatRole` gains `assistant`. `ChatMessage` gains content parts: text, and an image as a `data:` URL. A message with only text encodes exactly as today, so the enhancer's request bytes do not change (a test pins this against the current encoding).
  2. `ChatRequest` gains an optional JSON schema, sent as `response_format` only when set.
  3. `withEnhancerLease(…, rewarmsDisplaced:)` (KTD5).
  4. `switchModel` keeps a caller-supplied set of ids at tier 2 and above, with the one retry on a memory refusal (KTD6).
- **Tests:** request encoding with and without parts and schema; a lease with `rewarmsDisplaced: false` releases at once and re-warms nothing; a switch at tier 2 leaves the kept id loaded and at tier 1 unloads it; a refused load unloads the kept id and loads on the second try.

### U4. Catalog kind and the agent entry (layer 3, `agent/catalog`)

- **Files:** `Sources/MCCatalog/Catalog/Catalog.swift`, `Sources/MCCatalogTool/*`, `catalog/models.src.json`, `Sources/MCCatalog/Resources/catalog.json(.sig)`, `Sources/MCApp/Models/ModelBrowserModel.swift` and its views, `NOTICE`, tests.
- **Approach:** `CatalogModelKind.agent`; the entry from U1; `mc-catalog build`, `sign`, `verify`; the browser lists agents in their own group after enhancers; `agentStatus`, shaped as `enhancerStatus` is. The Recommender still considers image models only.
- **Tests:** kind round-trip with unchanged bytes for existing entries; `agentStatus` for not installed, installed, and installed but not listed by the engine; the bundled catalog verifies.

### U5. Conversation storage (layer 4, `agent/library-chat`)

- **Files:** `Sources/MCLibrary/LibraryStore+Chat.swift`, `Sources/MCLibrary/ChatMessage*.swift`, one registration line in `LibraryStore.swift`, `Tests/MCLibraryTests`.
- **Approach:** KTD8. API: append, list (newest N, and older pages), update a message's body (a card or question changes state), clear a collection's conversation. Payload kinds: `userText`, `agentText`, `question` (text, suggestions, chosen), `result` (sentence, job id), `download` (items, state), `adultNotice`, `error` (text, retry).
- **Tests:** order and paging; body update; clear leaves images and jobs; collection delete cascades; a v11 database migrates and keeps its rows.

### U6. `MCAgent` (layer 5, `agent/core`)

- **Files:** `Package.swift`, `Sources/MCAgent/` (`AgentContext.swift`, `AgentPrompt.swift`, `AgentPlan.swift`, `AgentPlanParser.swift`, `PlanResolver.swift`, `AgentReview.swift`, `Resources/Guides/*.json`), a public pack accessor and the shared rule constant in `Sources/MCEnhancer/`, `Tests/MCAgentTests`.
- **Approach:**
  1. `AgentContext`: messages, referent (settings, JPEG), model options (key, family record, guide, fit), LoRA options (key, description, trigger words, tested scale, `nsfw`, installed), flags (`mayAsk`, adult opt-in).
  2. `AgentPrompt.request` builds the `ChatRequest` (KTD14) and the schema (KTD2).
  3. `AgentPlan` (what the LLM wrote): `say(text)`, `ask(text, suggestions)`, `generate(text, model, prompt, size, seed: keep or new, loras: [(key, scale)], count)`. `ResolvedPlan` (what the app does): `say`, `ask`, `generate(draft, droppedAdultLoRAs)`, `proposeDownload(items, then: the plan)`, `invalid(reason)`. The LLM has no download action; the resolver produces the proposal.
  4. `PlanResolver`: unknown model key is invalid; size word to preset; unknown LoRA keys dropped; LoRAs that do not fit the chosen model dropped; scales clamped to −2…2; LoRA count capped at two (KTD22) and by `GenerationComposer.maxLoRAs`; count clamped to 1…4; `keep` seed without a referent becomes `new`; trigger words of the kept LoRAs re-inserted with the enhancer's `TriggerWordMatcher`; curated `nsfw` LoRAs dropped and flagged when the opt-in is off (KTD16); an uninstalled LoRA or model turns the plan into a download proposal; `ask` when `mayAsk` is false is invalid (AE2).
  5. `AgentReview`: the check request and its `{match, issue}` parser.
  6. `PlanTextStreamer` (KTD21).
- **Tests:** permanent tests on resolver rules (AE1, AE2, AE4 and each rule above), on the parser with fenced, truncated and extra-text replies, and on the streamer (deltas split inside an escape and inside a multi-byte character, `text` absent, `text` after other fields, a `"text"` key nested in another field ignored). None pins prompt wording.

### U7. The turn (layer 6, `agent/turn`)

- **Goal:** R8, R11 to R21, R31, without UI.
- **Files:** `Sources/MCApp/Chat/ChatModel.swift`, `ChatModel+Turn.swift`, `ChatModel+Context.swift`, `ChatReferent.swift`, a few lines in `AppModel` to own and feed it, `Tests/MCAppTests/Chat*Tests.swift`, `AppHarness` (an agent model in the fake engine and catalog).
- **Approach:** send appends the user message and starts a turn: build context, lease, chat (the sentence streams into the pending message, KTD21), parse, resolve, enqueue through the composer, append the result message, follow the job through the executor's events to done, failed or cancelled. Stop cancels the chat task or the job. Messages reload on collection switch. Failures map through the existing `message(for:)` copy (R31). KTD12 and KTD18.
- **Tests:** F1 against the stub engine (the job's request carries what the plan said, after resolution); AE3; AE5; AE6; an unreadable plan retried once then reported; a paused queue reported with Resume; engine failure mid-turn leaves the user message and an error message.

### U8. Cards, notice and check (layer 7, `agent/cards`)

- **Goal:** R24 to R30.
- **Files:** `Sources/MCApp/Chat/ChatModel+Downloads.swift`, `ChatModel+Onboarding.swift`, `ChatModel+Review.swift`, `Sources/MCApp/Shelf/ShelfModel.swift` (an install that does not attach to the stack), `Sources/MCApp/Models/ModelBrowserModel.swift` (start an install with an acceptance made on the card), tests.
- **Approach:** KTD11, KTD15, KTD16. The onboarding card appears when the agent LLM or every image model is missing; a waiting request starts when both exist (AE7). The check leases the LLM after `imageSaved` for a single-image job.
- **Tests:** AE4; AE7; card acceptance records the license version and starts installs in order; a shelf LoRA installed from a card is in the library and not on the stack; the check appends a message only on a miss and is skipped for multi-image jobs and after a newer user message.

### U9. Chat mode UI (layer 8, `agent/ui`)

- **Goal:** R1 to R7, R9, R10 on screen.
- **Files:** `Sources/MCApp/AppModel+Live.swift` (moved code, KTD9), `AppModel.swift`, `MainWindow.swift`, `MainCommands.swift`, `Sources/MCApp/Chat/ChatModeView.swift`, `ChatContainer.swift`, `ChatMessageRow.swift`, `ChatCards.swift`, `ChatLargeImage.swift`, `GalleryCollectionView.swift` (placeholder items, a bottom inset; split the file if it nears the budget), `Design/MCTokens.swift`, `UITests/MLXCreateUITests`, `scripts/gui-smoke/run_smoke.py`.
- **Approach:**
  1. `MainWindowMode` (KTD9); commands for the three modes; ⌘↩ and ⌘E are disabled in Chat mode; ⌘. stops the turn there.
  2. `ChatModeView`: the gallery, or the large image, with `ChatContainer` in a bottom overlay. The grid's bottom content inset equals the folded container's height (R3).
  3. `ChatContainer`: an opaque control-background panel with a hairline and shadow, so text keeps contrast over thumbnails (V02); tokens for its width, radius and unfurled fraction go in `MCTokens.swift`. The text box grows to five lines; Return sends, ⇧Return breaks the line. Focus is in the text box on entering the mode.
  4. Accessibility: labels on Send, Stop, the chevron and card buttons; a new agent message is announced; the unfurl animation respects Reduce Motion; every control is reachable by Tab (I07).
  5. Numbers on cards follow the locale rules (V03): sizes through `.formatted`, identifiers through `Text(verbatim:)`.
  6. The existing GUI smoke switches to Canvas (⌘2) before it generates.
- **Tests:** mode default and the legacy Boolean mapping (replacing `WindowModeTests`' expectations); placeholder projection per job state. Views are checked by the smoke, not by `swift test`.

### U10. Smokes and closing docs (layer 9, `agent/smoke`)

- **Files:** `UITests/MLXCreateUITests/ChatFlow.swift`, `scripts/gui-smoke/run_smoke.py` (`--agent-model-id`), `docs/lld/gui-smoke.md`, `scripts/gui-smoke/README.md`, `docs/lld/agent.md` (smoke results), `AGENTS.md` (commands).
- **Approach:** a Chat flow in the GUI smoke (type a request, wait for a tile, open it, type a refinement, wait for the second tile), and the real-engine session below.

## Verification Contract

| Gate | Command or action |
|---|---|
| Build and tests | `swift build`, `swift test` per layer (about 40 s; past 2 minutes it is hung, see AGENTS.md) |
| Format and size | `git ls-files '*.swift' \| xargs swift format lint --strict --configuration .swift-format` prints nothing; `node scripts/check-file-size.mjs --all` lists nothing |
| Catalog | `swift run mc-catalog verify Sources/MCCatalog/Resources/catalog.json` |
| Engine lock | `sh scripts/engine-contract/check_lock.sh engine.lock` (the pin does not change) |
| App build | `xcodegen generate`, then the Debug `xcodebuild` from AGENTS.md |
| GUI smoke | `run_smoke.py` with the Canvas flows and, from layer 9, the Chat flow; exit 2 is NOT RUN, never a pass |

Real-engine session on this Mac (layer 9), in a throwaway home with FLUX.2 klein 4B, Qwen-Image 2.1 Turbo and the agent LLM linked in:

1. First request in English; observe the PNG, its `parameters` and `mlx-create` chunks, the `image` and `chat_message` rows.
2. A refinement with the image shown large; the new job's request derives from that image's settings.
3. "Give me three options"; three images, no check message.
4. A request for readable text in the image; note which model the plan chose.
5. An explicit request with the opt-in off; the notice appears once; switch on, Retry.
6. A request in Spanish; the reply is Spanish, the stored prompt English.
7. Stop during thinking and during rendering.
8. Relaunch; the conversation is restored. `pgrep mlx-serve` is empty after quit.
9. The same session's first three steps with the tier forced to 16 GiB, timing the swaps.

## Definition of Done

- Every gate passes on every layer; the real-engine session's nine steps are passed or reported as not exercised with the reason.
- U1's results and the session's results are in `docs/lld/agent.md`.
- No Chat-mode view shows a model name, LoRA name, prompt, seed or size outside a download card.
- `docs/HLD.md`, `AGENTS.md` and the spike file describe the shipped behaviour; D58 still reads provisional.
