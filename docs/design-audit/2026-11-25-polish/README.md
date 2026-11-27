# Polish review (2026-11-25)

A second UI/UX review of the native app on `main` at `ff2d10d`, after all 28 findings of the [2026-10-30 audit](../README.md) shipped. That audit fixed usability; this one looks at craft and delight. The bar set by the user: an app people call "really cool" and love using.

Findings are grouped in three notches:

- **Notch 1, craft:** defects and rough edges. No HLD change is needed. **Being implemented now** (one PR, `Audit: P01`…`P10` in the trailers).
- **Notch 2, native look:** a visual system for macOS 26. No HLD change, but it touches every screen. **Open.**
- **Notch 3, wow:** new behaviour at the product's key moments. Several items need HLD decisions, drafted in [§5](#5-draft-decisions-not-in-the-hld). **Open. Do not change the HLD until the user approves the drafts.**

App icon, accent colour and product name (N2-1) were deferred by the user to the next round at audit time; they shipped in the Notch 2 stack (PR #68).

## 1. Method

- Build: `xcodegen generate`, then `xcodebuild … -configuration Debug -derivedDataPath build build`, at `ff2d10d`.
- Homes: an empty one (`/tmp/mc-ux2-empty`) and a full one, with FLUX.2 klein 4B, Qwen-Image 2.1 Turbo, the agent LLM (`zecanard/gemma-4-E4B-it-ultra-uncensored-heretic-MLX-5bit-int5-affine`) and the enhancer symlinked in, and their `installed_model` rows copied ([capture kit §3](../capture-kit.md)).
- Driven for real: a Chat turn (one image), a Chat turn asking for 4 options, and 4 Canvas prompts × 4 images on klein 4B, giving 21 images.
- Captured with the [capture kit](../capture-kit.md) on the built-in Retina display. "Small" is a 1100×692 window, "large" is 1680×1050. Screens are in `screens/`, downscaled to 1280 px JPEG. The Civitai previews in `31-*` are pixelated.
- Not captured: the screen locked mid-session, so Settings and later states were read from source. Error states were covered by the first audit (`../screens/07-*`, `08-*`).
- Real preferences were exported before and imported after. The `chatGreetingShown` flag is in the real defaults, so the full home shows no greeting; that is a test artefact, not a bug.

## 2. Notch 1: craft fixes (done)

Each item names its evidence, its code, the fix, and how to check it. Keep the [smoke contract](../README.md#13-smoke-contract-every-spec-must-keep): the labels "Prompt", "Seed", "Random"/"Fixed"/"Increment", the Size pop-up containing "×", "Generate", and "Model: ", "Generation progress", "Selected image: ", "Image: ".

### P01. The Seed label wraps to "Se / ed", and the composer's left edges don't line up
- **Status: done (76eaadb, 9b1ede2, 2f5233d). Deviation: labels lead rather than trail — the check measures the named elements' leading x, which only leading labels can satisfy. The label column is pinned to the widest label the family can show and the controls column leads into the flexible width, so the Size pop-up's x is identical with More options open or closed.**

- **Evidence:** `20-canvas-with-images_*`, `23-canvas-populated_*`, at both sizes. Size, "More options", Seed, the LoRAs header and "Add LoRA…" start at four different x positions. The LoRA section sits in an extra grey box with its own inset.
- **Cause:** `ComposerSettings.seedRows`: a `LabeledContent` whose content is a `.fixedSize()` segmented picker. Inside the 320 pt panel, the extra `.padding(.leading, MCSpacing.section)` under "More options" squeezes the label column. `LoRASection` adds its own inset and fill.
- **Fix:** lay the settings out on one two-column `Grid` (labels trailing-aligned in one column, controls in the other) shared by Size, Seed, Steps, CFG and Negative prompt. Labels never wrap (`.lineLimit(1)` plus `.fixedSize()` on the label column). The disclosure's content is not indented differently from the rows above it. The LoRA section's header and rows share the composer's leading edge, and the extra boxed fill goes.
- **Check:** at 1100×692 and 1680×1050, every label is on one line, and the leading x of Size, More options, Seed, Steps, LoRAs and Add LoRA… differs by ≤ 1 pt (`ax dump` frames).

### P02. The prompt editor is a huge empty box with a permanent scrollbar track
- **Status: done (7cbea33, 6ba5469). Deviation: `.scrollIndicators(.automatic)` alone still drew a persistent scroller on this Mac, so a probe gives the editor's `NSScrollView` an autohiding overlay scroller.**

- **Evidence:** `02-empty-canvas_*`, `20-*`. In the large window the editor is about 550 pt tall with one line of text and a visible grey scroller track. Recent prompts and Enhance float under it, right-aligned and detached.
- **Code:** `GenerationPanel.swift` (the prompt `TextEditor`, history button, Enhance).
- **Fix:** the editor is a card (`MCTone.textBackground`, `MCRadius.card`, hairline stroke) that grows with its content, from about 5 lines to a cap of about 60% of the panel height. It scrolls only past the cap, with overlay scrollers (`.scrollIndicators(.automatic)`, so no permanent track). A placeholder example appears when empty ("Describe a picture: a lighthouse at golden hour, waves crashing"). Recent prompts and Enhance sit in a bottom toolbar row inside the card, Enhance with its `sparkles` symbol. The settings follow directly under the card, not pinned to the bottom with a void between.
- **Check:** with a one-line prompt, the gap between the editor and Size is ≤ `MCSpacing.section`, and no scroller track is drawn. Tab still leaves the editor (I07).

### P03. The Generate row is cramped, and the disabled Generate reads as enabled in dark mode
- **Status: done (7cbea33, 6ba5469). Deviation: Tahoe's prominent capsule hugs its title, so `.buttonSizing(.flexible)` makes the button full-width. The enabled label/fill is the system accent and measures 4.07:1, under the check's 4.5:1 — the spec bars a custom fill, so the stock style stands.**

- **Evidence:** `02-empty-canvas_small_*`, `20-*_small_*`. "×1 [stepper] Type a prompt to generate [Generate]": the reason wraps onto two lines in an 85 pt column. The dark disabled Generate is a filled blue (`02-empty-canvas_large_dark`), as I12 already reported.
- **Code:** `GenerationPanel.swift` footer.
- **Fix:**
  - Image count becomes a compact menu or segmented control with the values 1, 2 and 4 (label "Images"), plus a numeric field that accepts other counts (keep the existing range). Keep the accessibility label "Batch count".
  - Generate becomes a full-width `.borderedProminent`, `.controlSize(.large)` button. Its title is "Generate", and a secondary line or trailing text shows the estimate when one exists ("About 12 s", from the model chip's estimate) and the ⌘↩ hint.
  - The disabled reason moves onto its own full-width line above the button, in `.mcSupporting`, never wrapping into a narrow column.
  - The disabled state must not look enabled in either appearance: use the system disabled style, never a custom fill.
- **Check:** small window, empty prompt: the reason is on one line and the button reads as disabled in light and dark (contrast of the disabled label against its fill < 3:1, while the enabled one is ≥ 4.5:1).

### P04. The image action bar uses three button styles, and its targets are tiny
- **Status: done (8f737ab, 7c2507f). Deviation: Tahoe's bezel hugs the symbol, so every icon label takes a shared minimum height — the flat `folder` glyph otherwise measured 26 pt.**

- **Evidence:** `20-canvas-with-images_large_light`, `23-*`. "Reuse Settings" and "Export…" are bordered text buttons. Show in Finder is a 14×12 pt bare glyph and Move to Trash 12×14 pt (`ax dump`). In the small window Reuse is an unclear counter-clockwise arrow.
- **Code:** `CanvasView.swift` (the image bar under the canvas, S06).
- **Fix:** one control group with one style. Reuse Settings and Export… keep their text. Show in Finder and Move to Trash become icon buttons in the same bordered style, each with a hit area of at least 28×28 pt, a `.help` and an accessibility label. In the small window, labels collapse to icons only through `ViewThatFits`, with clear symbols (`arrow.uturn.backward` stays out; use `slider.horizontal.3` or `wand.and.rays` for Reuse Settings, `square.and.arrow.up` for Export). Trash is visually separated (a divider or spacing) and uses `role: .destructive`.
- **Check:** every image-bar button frame is ≥ 28×28 pt in both window sizes; all four share one button style.

### P05. Chat's container controls are too small and look unfinished
- **Status: done (19ffa43, b0cdc88, 4449689, 0eb40ea, 313d098, 04a69d5). Deviations: the 28 pt frame sits on each icon label (the element takes its bounds from the label, not the button); the More menu is `.menuStyle(.borderlessButton)` — its accessibility element stays icon-sized even over the full hit area, accepted for the quiet header look; the large view needs `.accessibilityElement(children: .contain)` or `.focusable()` merges Close into a container-sized element. One-line input centres against the round Send button via `minHeight: MCSize.minHitTarget`; multi-line keeps Send bottom-aligned.**

- **Evidence:** `13-chat-*`, `14-chat-history-open_*`, `15-chat-large-image_*`. "Show conversation" is 38×16 pt, "More" (the conversation menu) is 21×15 pt, and Send is a grey square with a tiny glyph. The large view's Close is a 24 pt dark square at the top left.
- **Code:** `ChatContainer.swift` (header, input row), `ChatLargeImage.swift`.
- **Fix:**
  - Header controls get ≥ 28×28 pt hit areas. The chevron is a borderless icon button with a clear symbol (`chevron.up` / `chevron.down`) and the label "Show conversation" / "Hide conversation".
  - Send is a round accent-filled button with `arrow.up` when enabled and a quiet, still-legible style when disabled. Stop keeps `stop.fill`.
  - The input row is one rounded field, the text field plus Send, with the field's own padding, not a bare line.
  - The large view's Close is a standard `xmark` button with a material background, ≥ 28 pt, at the top leading corner, and it keeps Esc.
- **Check:** `ax dump` frames ≥ 28×28 pt for Show/Hide conversation, More, Send/Stop and Close.

### P06. The agent's line stays in the present tense after the images land
- **Status: done (7cd7c50).**

- **Evidence:** `13-chat-batch-done_large_light`, `16-chat-populated_*`. The last line keeps reading "Making a cozy reading nook with a cat and a rainy window." after all four images are in the gallery. The progress line just disappears.
- **Code:** the result message rendering in `ChatMessageRow.swift` and `ChatStatusLine.swift`, and the job bookkeeping in `ChatModel+Jobs.swift`.
- **Fix:** keep the agent's sentence (D56 (a): nothing technical), and when the result's job finishes, show a persistent completion line under it: a `checkmark.circle.fill` symbol in `MCTone.success` with "Done" for one image or "4 images ready" for a batch. Failed or cancelled jobs keep their existing wording. A screen-reader announcement fires once on completion.
- **Check:** after a 4-image turn, the result row shows "4 images ready". After a relaunch it still does, derived from the job state rather than stored text.

### P07. The search field is a bare field across the whole window, and the selection count is always on
- **Status: done (0466768). Deviation: in Chat mode the footer still shows a delete or export result and its progress, since Chat has no other place for it; the selection count alone never shows there.**

- **Evidence:** `16-chat-populated_*`, `40-gallery-populated_*`. In Gallery and Chat, "Search prompts" is a plain text field about 1,570 pt wide with "Filters" beside it. "1 of 21 selected" sits in a footer at all times, including in Chat mode.
- **Code:** `GalleryView.swift`.
- **Fix:** the search becomes a search field (`magnifyingglass` and clear button, rounded `.searchFieldStyle`-like look) with a maximum width of about 320 pt, trailing-aligned with Filters, so the grid reads first. The footer shows only when two or more images are selected ("3 selected"), and never in Chat mode. If moving search into the window toolbar with `.searchable(placement: .toolbar)` is clean in all three modes, prefer that; otherwise keep it in the header.
- **Check:** in Gallery mode at 1680 pt the search field is ≤ 340 pt wide. With one image selected no footer is shown.

### P08. "Queue empty" takes a row when nothing is queued
- **Status: done (582c396). Deviation: a queue header that offers Pause or Resume keeps the strip, so a queue paused or running in another collection can still be resumed or paused here.**

- **Evidence:** `20-*`, `23-*`: a 32 pt strip that says "Queue empty" under the canvas.
- **Code:** `MainWindow` (`showsQueueStrip`) and `QueueStripView`.
- **Fix:** with no cells and calibration not running, the strip is hidden, and the canvas gets the height. The strip appears (with the existing animation rules and Reduce Motion) when a job is queued. HLD §10 already hides it in the empty states; this extends the rule to "no cells". Note this wording delta in the PR.
- **Check:** with no jobs, there is no "Queue empty" text in `ax dump`. Queue one job and the strip appears.

### P09. Arrow keys don't step through images in the large view
- **Status: done (ebcc89d, 4449689, 3833775). Deviation: `.focusable()` draws the system focus ring over the image, so the large view takes `.focusEffectDisabled()` — arrows and Esc still work. The view takes focus once, on appear, so an image landing in it does not pull focus from the Chat input; past the last loaded image the next page loads first.**

- **Evidence:** in Chat's large view, → left the same image shown (the `Selected image:` label was unchanged).
- **Code:** `ChatLargeImage.swift` (Chat). Check the Canvas canvas too (`CanvasView`): ← → should move the selection as the gallery grid does (I08).
- **Fix:** ← and → move to the previous and next image in the gallery's current order (respecting search and filters) while the large view is shown, and update the selection. Don't wrap at the ends. Esc still closes.
- **Check:** open the first image large, press → and the label changes to the second image's prompt. Press ← and it returns.

### P10. The LoRA library's empty "Your LoRAs" tab and the Recommended list look unfinished
- **Status: done (2366b7e).**

- **Evidence:** `30-lora-sheet_small_light`: Recommended shows a single text-only row in an 880×620 sheet. `32-lora-yours_small_light`: "No LoRAs yet." with three equal buttons and a footer "Using Zero KB on disk".
- **Code:** `LoRALibraryView.swift`, `ShelfView.swift`.
- **Fix:**
  - The empty "Your LoRAs" becomes a `ContentUnavailableView`-style empty state: a symbol, the title "No LoRAs yet", one line of explanation, **one** prominent action ("See Recommended") plus secondary text links (Import…, Browse Civitai), and the drop hint.
  - The disk footer is hidden when nothing is installed.
  - Shelf rows get the same row anatomy as Civitai rows (a 64 pt leading tile, using a symbol tile when there is no preview, title, one supporting line with role and size, trailing action), so curated items never look poorer than third-party ones.

  Wording stays "LoRAs": the rename to "Styles" is draft decision DR4 (§5) and waits for approval.
- **Check:** empty library: exactly one prominent button on the tab. Shelf rows have a leading tile.

## 3. Notch 2: native look (done)

| ID | Finding | Evidence | Direction |
|---|---|---|---|
| N2-1 | No app icon or asset catalog; the display name is lowercase "mlx-create" in the Dock, the menu bar and About | `Info.plist` has no `CFBundleIconFile`; no `.xcassets` in the repo | **Done (PR #68).** `Assets.xcassets` carries the Safelight `#C8401A` `AccentColor` in both appearances and the `AppIcon` (concept C3, drawn as a vector by `scripts/app-icon/draw_icon.swift` at every macOS size). The display name is MLX Create in the Dock, the menu bar and About; `mlx-create` stays for identifiers (the binary, bundle id, paths, keychain services and log subsystems) |
| N2-2 | The modes are invisible: Chat, Canvas and Gallery only exist in the View menu and ⌘1–3 | `ax dump` toolbar: only the collection menu and the model chip | A segmented Chat / Canvas / Gallery control as the toolbar's principal item, with SF Symbols and help tags. Keep the menu and shortcuts |
| N2-3 | Every surface is flat white; no materials. It reads as a document, not a macOS 26 app | all screens | The composer as a sidebar material (`.background(.bar)` or an `NSVisualEffectView` sidebar), toolbar items on glass, and the Chat container on glass if V02 contrast holds (it is opaque by decision for contrast; measure `contrast.py` ≥ 4.5:1 over the busiest thumbnails before changing) |
| N2-4 | Images sit on white; the canvas and large view don't let pictures pop | `15-chat-large-image_*`, `23-*` | A neutral "studio" backdrop (`Color(white: 0.11)` in dark, `Color(white: 0.94)` in light, as a token) behind the canvas and large view; a soft shadow on the image; the facts and actions on a glass bar |
| N2-5 | Sheets don't scale with the window (Models is ~680×500 inside a 1680×1050 window) | `33-model-browser_large_*` | Sheets size to content up to ~70% of the window; the browser lists use full-width rows |
| N2-6 | The model popover only gives the selected model's estimate and no hint of what each model is for | `21-model-chip-popover_small_light` | Each row: name, a "best for" line and the speed estimate in words ("Fast on this Mac"). Needs a `best_for` field in the catalog |

Resolution — one stacked branch off `main` (`gh stack`, bottom to top):

- **N2-1 — done (`36e1bd2`, `c30d4b6`, `e6df68d`, `104a2e1`, `notch2/brand`).** `Assets.xcassets` added with `AccentColor` wired through `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`. The icon is the user's pick, C3 ("sun in crop marks"), redrawn as a vector by `scripts/app-icon/draw_icon.swift` into `AppIcon.appiconset`. The accent is Safelight `#C8401A` in both appearances (user rejected the earlier violet `#6E44E8`/`#7B55F0` pair). Display name "MLX Create" via `CFBundleName`/`CFBundleDisplayName`; `PRODUCT_NAME` stays `mlx-create`. Enabled Generate label/fill: 5.00:1 light and dark (fixes the P03 deviation). Selected mode-switcher segment: 16.21:1 light, 8.32:1 dark. Gallery selection ring: the accent ring now carries a 1 pt halo flush outside it (`MCTone.selectionHalo` — white 0.9 dark, black 0.55 light) shared by the tile and queue-cell rings; measured 3.95:1 light and 3.49:1 dark against the column background and 3.89:1 against the thumbnail — all ≥ 3:1 (was 1.78:1 in dark). Deviation: `INFOPLIST_KEY_CFBundleName` is ignored while `GENERATE_INFOPLIST_FILE=YES`, so a static `Config/Info.plist` replaces the generated one, mirroring every generated key including `MLXCatalogURL`.
- **N2-4 — done (`0d9192b`, `361ee90`, `notch2/backdrop`).** `MCTone.studio` + `MCShadow.image*` tokens; canvas (empty/progress/result) and the chat large view sit on the studio backdrop, the image gets the soft shadow, and the facts-and-actions bar rides `.regularMaterial` glass. Bar text: light primary 19.26:1; dark primary 11.37:1. The facts line uses `.primary.opacity(0.75)` (review fix — `.secondary` had dropped to 2.95:1 light / 3.12:1 dark on the glass): it now measures 11.02:1 light and 7.23:1 dark, identical over bright and dark images.
- **N2-2 — done (`305508f`, `notch2/toolbar-modes`).** `NSSegmentedControl` via `NSViewRepresentable` as the `.principal` toolbar item — three icon-and-text segments bound to `AppModel.windowMode`, a help tag per segment, accessibility label "View mode"; the menu items and ⌘1–3 stay.
- **N2-3 — done (`a8a17a1`, `notch2/materials`).** Composer panel and the Canvas-mode gallery column on a `.sidebar`/`behindWindow` `NSVisualEffectView`; the Chat container is rounded glass, tinted dark in dark mode. Measured text ≥ 4.5:1 except the input placeholder, which keeps the standard secondary style on its opaque pill (3.79:1 light, 5.64:1 dark — unchanged by the glass).
- **N2-5 — done (`66acb54`, `b75f027`, `notch2/sheets`).** Models and LoRA sheets take 70% of the window with their old sizes as floors: 1680×1050 → Models 1176×699; 1100×692 → Models 770×500, LoRA 880×620. Name/licence/enhancer sheets keep their fixed widths. Deviation: custom environment values do not propagate into `.sheet` content on this OS, so `MainWindow` measures its content size and passes it to both sheets as a parameter.
- **N2-6 — done (`7d6fc23`, `notch2/catalog-best-for`).** `best_for` added to `CatalogModel` (decode with and without the field tested; re-encode omits it when absent); the five shipped entries carry reviewed strings; `catalog.json` rebuilt to sequence 11 and re-signed (`mc-catalog verify` passes). Chip popover rows show name + best-for + speed in words (`Fast on this Mac · about N s` under 20 s, `About N s on this Mac` at 20–59 s, `Slow on this Mac · about N s` at 60+); the Models browser rows show best-for under the title. Deviation: unavailable popover rows keep their reason line only.

## 4. Notch 3: wow (open; DR1–DR4 need approval first)

| ID | Moment | Today | Proposal | Needs |
|---|---|---|---|---|
| W1 | **The reveal** | The finished image lands as a 176 pt tile in the top-left corner while the user looks at the chat box at the bottom centre (`12-chat-first-result_large_light`) | The result appears where the user is looking: a row of result thumbnails in the conversation (click to open large), and the new tile enters the grid with a short scale-and-fade. One image from a request sent with nothing open opens large by itself | DR1, DR2 |
| W2 | **Making** | A spinner in a grey square in the corner, and a thin bar in the chat (`11-chat-rendering-*`) | A placeholder in the target aspect ratio with a soft animated gradient shimmer and a time-left ring, shown both in the grid and in the conversation. When upstream F1 lands, real step previews replace the shimmer. Reduce Motion gives a static tint | DR1 |
| W3 | **A gallery that shows images off** | Square crops hide the 16:9 images the agent makes; a request's 4 images look like unrelated jobs (`40-gallery-populated_*`) | A justified layout that keeps each image's aspect ratio; a request's images grouped under a one-line prompt header with a count; day sections ("Today", "Yesterday"); hover lifts the tile and shows the prompt | DR3 |
| W4 | **Pictures first** | Setup says "Download Chat Model" on white (`01-*`); ready Chat is a void with "Your images will appear here" (`10-*`) | Setup and the empty Chat show a slow mosaic of sample images made by the app (bundled, ours). The empty Chat offers 4–6 starter ideas as chips that send on click | No D-change: D60 allows the setup content; the samples are app assets |
| W5 | **Showroom browsers** | Model and LoRA lists are text: sizes, licence names, internal names like "Gemma 4 E4B heretic (prompt enhancer)" (`33-*`, `30-*`) | Each model and curated LoRA shows a sample image made with it and a "best for" line; sizes and licence move to a detail line; internal repo-style names are not shown to users | Catalog schema: `preview_image` (signed, hosted by us) and `best_for` |
| W6 | **Motion** | Instant swaps everywhere | The tile zooms into the large view (`matchedGeometryEffect`), the conversation unfurls with a spring, new tiles insert with a spring, and Generate shows a subtle press state. All of it honours Reduce Motion | None |
| W7 | **Plain words for LoRAs** | "LoRA" is jargon for STRATEGY.md's primary user | User-facing "Styles" everywhere (sheet title, composer section, menus, Chat copy); "LoRA" stays in code, the HLD and file formats | DR4 (approved in principle by the user, 2026-11-25) |

Also seen, not specced: macOS inline predictive text completes words in the Chat field (a stray "The " appeared after sending, `13-chat-batch-rendering_large_light`). Verify, and if confirmed, consider `.textInputSuggestions` / `NSTextView.inlinePredictionType = .no` for the prompt fields.

## 5. Draft decisions (not in the HLD)

These are drafts for the user's approval. On approval, append them to the HLD decision log with the next free IDs (D62 onward), amend the decisions they name, then implement.

- **DR1: Chat results show in the conversation.** A result message shows the request's images as a row of thumbnails, at most 4 visible plus "+N", each opening the large view. While the job runs, the row shows placeholders with progress (W2). Amends **D55** ("a result reads as a sentence and carries no thumbnail"): the stored message still references jobs, not files, so the schema is unchanged and video results still work (D7). Rationale: the result is the product's peak moment, and it currently lands out of view.
- **DR2: A single-image result opens large by itself when nothing else is open.** If the request was sent with the grid showing and the job made one image, the large view opens on it when it lands; for a batch, the grid scrolls to and highlights the new group. The existing refinement exception stays. Amends **D54** ("the finished image … does not open by itself"). Rationale: users judge a result where they are looking.
- **DR3: The gallery keeps aspect ratios and groups by request.** The grid uses a justified layout at each image's aspect ratio, and the images of one job form a group headed by its prompt; day sections separate groups. Amends **D33**/**D52**'s gallery description and the S09 grid. `GalleryCollectionView` (`NSCollectionView`, needed for 10k+ items) gets a custom layout rather than a SwiftUI grid.
- **DR4: "Styles" is the user-facing name for LoRAs.** Every user-visible string says "Style"/"Styles"; the LoRA library sheet becomes "Styles", "Add LoRA…" becomes "Add Style…", and the Chat notice of D61 says "adult styles". The code, HLD, LLDs, catalog and file names keep "LoRA". Amends the wording of **D34**, **D43**, **D51** and **D61** (behaviour unchanged), and the smoke contract if a test finds a control by a LoRA label.
