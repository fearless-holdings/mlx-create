# V05 · One badge style, and no label that repeats its button

| | |
|---|---|
| Tag | VISUAL |
| Severity (Nielsen 0–4) | 2, minor: the model and LoRA lists say everything twice ("Not installed" beside Install, "Fits this Mac" on every row, "Fits FLUX.2 klein" and "Available" on every Civitai row, "In stack" next to "Already in the stack"); badges wrap mid-word ("Recom-/mended") |
| Frequency | Every visit to the model browser, the first-run card and the LoRA sheet |
| Heuristics | H8 Aesthetic and minimalist design; H4 Consistency and standards |
| User task | (a) choosing the first model; (d) adding a LoRA |
| Strategy metric | Nothing to learn ("no decision the user can't make": the row should say only what differs) |
| HLD decisions | No D* change. D42 (Recommended) and the fit bands (§8.5) still show. Only the always-true "comfortable" band stops showing as a badge |
| Size | M |
| Depends on | V01 (tokens). Do it after S01 (first-run card) and S03 (model chip), which already drop some of these labels |

## Evidence

- Screenshots: `screens/05-model-browser_small_light.png` (every row "Fits this Mac" and "Not installed"; the recommended model is third); `screens/02b-model-downloading-main_small_light.png` (badges wrap: "Fits this / Mac", "Recom-/mended"); `screens/11-lora-civitai_small_light.png` ("Fits FLUX.2 klein" and "Available" on every row, under a filter that already shows only fitting LoRAs); `screens/10e-lora-installed-detail_small_light.png` ("In stack" badge, "Already in the stack" text and a disabled Add, all on one row).
- Code:
  - `Sources/MCApp/Models/InstallRow.swift`: `fitLabel`, the `Recommended` capsule, `stateView` `.available` → "Not installed", `facts(for:)` with quantization first.
  - `Sources/MCApp/Models/ModelBrowserModel.swift`: `rows` in catalog order.
  - `Sources/MCApp/Civitai/CivitaiBrowseView.swift`, `CivitaiResultRowView` (`badge`, `statusView` `.available` → "Available").
  - `Sources/MCApp/LoRALibraryView.swift`, `LoRALibraryRow` (two capsules, `addBlockReason`).
- Three badge implementations with different fonts and paddings (V01 inventory).
- Comparison: Photos and Image Playground show no per-item state badges at rest. Draw Things lists every model with the same metadata, which is the noise the user dislikes.

## Target behavior

- **`MCBadge`** (new): `Text(text).font(.mcBadge)`, padding horizontal 6 and vertical 2, `Capsule()` fill `MCTone.cardFill` (neutral) or `Color.accentColor.opacity(0.2)` (accent), and `.fixedSize()` and `.lineLimit(1)` so it never wraps.
- **Model rows** (`InstallRow`):
  - Badges: "Recommended" (accent) only on the recommended row. "Tight fit" and "Exceeds this Mac" stay as an `MCStatusText(.warning, …)` line (V02). The "comfortable" band shows nothing.
  - No "Not installed" text when the action is Install.
  - Facts line: `"\(download) download · about \(ram) GB memory · \(license)"`. Quantization moves to `.help(model.quantization)` on the title.
  - Order in `ModelBrowserModel.rows`: the recommended image model first, then the catalog order, then enhancers, then unlisted folders.
- **Civitai rows:** the "Fits …" badge shows only when `showIncompatible` is on (it then tells the rows apart). The "Available" caption is removed. "NSFW" uses `MCBadge` (neutral).
- **LoRA library rows:** an "In stack" badge, without the "Already in the stack" reason. The "Just added" badge uses `MCBadge` (accent).

## Edit steps

1. Create `Sources/MCApp/Design/MCBadge.swift`:

   ```swift
   import SwiftUI

   /// A small capsule label (V05). Never wraps.
   struct MCBadge: View {
       enum Tone { case neutral, accent }
       let text: String
       var tone: Tone = .neutral

       var body: some View {
           Text(text)
               .font(.mcBadge)
               .lineLimit(1)
               .padding(.horizontal, MCSpacing.compact)
               .padding(.vertical, MCSpacing.hairline)
               .background(background, in: Capsule())
               .fixedSize()
       }

       private var background: AnyShapeStyle {
           switch tone {
           case .neutral: AnyShapeStyle(MCTone.cardFill)
           case .accent: AnyShapeStyle(Color.accentColor.opacity(0.2))
           }
       }
   }
   ```

2. `InstallRow.swift`:
   - In the title `HStack`, delete the `fitLabel` capsule. Replace the Recommended capsule with `MCBadge(text: "Recommended", tone: .accent)`. Add `.help(row.model?.quantization ?? "")` to `Text(row.title)`.
   - Delete `fitLabel`.
   - In `stateView`, change `.available` to `EmptyView()`.
   - In `facts(for:)`, return `"\(download) download · about \(ram) GB memory · \(model.license.name)"`. Format `ram` as in V03 (`model.ramGB.formatted(.number.precision(.fractionLength(1)))`).
3. `ModelBrowserModel.rows`: build `catalogRows`, then reorder: the row with `isRecommended` first, then the others in their existing order. Leave `rows(of:)` and `recommendedRow` working on the reordered array.
4. `CivitaiBrowseView.swift`, `CivitaiResultRowView`:
   - Wrap the "Fits …" badge as `if row.matchesSelectedModel && browse.showIncompatible { MCBadge(text: "Fits \(modelName ?? "the selected model")") }`.
   - Replace the private `badge(_:)` uses with `MCBadge(text:)` and delete `badge(_:)`.
   - In `statusView`, change `.available` to `EmptyView()`.
5. `LoRALibraryView.swift`, `LoRALibraryRow`:
   - Replace both hand-made capsules with `MCBadge(text: "In stack")` and `MCBadge(text: "Just added", tone: .accent)`.
   - In `addBlockReason`, return nil for `item.inStack` (the badge says it; Add is still disabled through a separate check). Change the button's `.disabled(addBlockReason != nil)` to `.disabled(addBlockReason != nil || item.inStack)`.
   - Also replace the "Just added" capsule in `CivitaiSourceSection`.
6. Tests: `Tests/MCAppTests/ModelBrowserRecommendationTests.swift` already builds browsers with a recommendation. Add `theRecommendedRowComesFirst`: with a catalog whose recommended model is not first, expect `browser.rows.first?.isRecommended == true`. Check existing tests that index `rows` by position (`rg -n "rows\[|rows.first" Tests/MCAppTests`) and update their expectations to the new order.
7. Format the touched files.

## Do not touch

- `FitBand` maths, `Recommender.pick` (D42), and the warnings for tight and exceeding models.
- License text, and the order of the license sheet and install.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including the new test (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. `rg -n '"Not installed"|"Fits this Mac"|"Already in the stack"|Capsule\(\)' Sources/MCApp --glob '!Design/*'` prints nothing.

With the capture kit and an empty home, at 1100×692:

6. Model browser: the first `AXStaticText` row title is the recommended model, and no static text reads "Fits this Mac" or "Not installed".
7. First-run card while a non-recommended model downloads (needs a download, so **ask the user first**; cancel within 60 s), and the browser: no badge wraps. Each `MCBadge` static text frame is one line high (≤ 18 pt).
8. Attach `V05_browser_small_light.png` and `V05_civitai_small_light.png` (previews blurred or NSFW off).

## Resolution

Done in [#46](https://github.com/fearless-holdings/mlx-create/pull/46). The change follows the edit steps. `Sources/MCApp/Design/MCBadge.swift` is the spec's component: `.mcBadge`, `.lineLimit(1)`, `.fixedSize()`, `MCSpacing.compact`/`.hairline` and a `Capsule()` fill, so it never wraps. `InstallRow` drops the fit capsule and "Not installed", moves quantization to a help tag and uses the new facts line; `ModelBrowserModel.rows` leads with the recommended row; Civitai rows show "Fits …" only when "Show incompatible" is on and no longer say "Available"; LoRA rows use `MCBadge` and no longer repeat "Already in the stack", with Add still disabled for in-stack items. The `theRecommendedRowComesFirst` test covers the new order.

Exercised: `swift build`; `swift test` (297 tests, including the new one); whole-tree `swift format lint --strict`; `xcodegen generate` + Debug `xcodebuild` (`BUILD SUCCEEDED`); the acceptance string grep — no "Not installed", "Fits this Mac" or "Already in the stack" remains in `Sources/MCApp` outside `Design/`. GUI smoke (D50) on 2026-11-16: passed, 13 screenshots in `build/gui-smoke/20261116-133940/`, with `Runpod/FLUX.2-klein-4B-mflux-4bit` symlinked into a throwaway home.

Not exercised: the capture-kit `ax dump` rows and screenshots (acceptance 6–8). This shell has no Accessibility grant for per-app UI inspection, so the badge frame heights and the model browser's first static text were not measured in the running app; the download-dependent badge-wrap check (7) also needs a fresh download. Two notes on the literal grep in acceptance 5: the remaining `Capsule()` in `CanvasView.swift` is the step-progress material pill, not a badge, and `MCBadge.swift` is under `Design/`, which the glob intends to exclude but `/Sources/MCApp/Design/` does not match from the repo root.
