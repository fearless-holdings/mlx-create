# S01 · First launch: one primary action instead of three

| | |
|---|---|
| Tag | STRUCTURE |
| Severity (Nielsen 0–4) | 4, catastrophe: it is the first screen every buyer sees, and it decides whether they reach an image at all |
| Frequency | Once per user, in the first minute; again whenever the library has no image model |
| Heuristics | H8 Aesthetic and minimalist design; H6 Recognition rather than recall; H1 Visibility of system status |
| User task | (a) First launch to first kept image |
| Strategy metric | Time to first kept image; "no decision the user can't make" (STRATEGY.md, Zero to first image) |
| HLD decisions | No D* change. Keeps D42 (recommendation) and D20 (license before download). Removes the enhancer offer from this screen (a plan-level item, F2/R16, not a D* decision) |
| Size | S |
| Depends on | none. I01 builds on the card this spec creates |

## Evidence

- Screenshots: `screens/01-first-launch-empty_small_light.png`, `_small_dark`, `_large_light`, `_large_dark`.
- Code: `Sources/MCApp/EmptyModelsView.swift`, `EmptyModelsView.body`; the card reuses `InstallRow` (`Sources/MCApp/Models/InstallRow.swift`).
- What a new user sees at 1100×640: a 40 pt `shippingbox` symbol, "No image models installed", a card holding a small grey `Install` button, a grey `Browse models` pill and a grey `Get the prompt enhancer` button. Three buttons share the same weight, none is prominent, and the one that matters (Install) is the smallest. The card repeats "Fits this Mac", "Recommended" and "Not installed" next to the very button that installs it. Meanwhile the 296×455 pt prompt editor on the left is enabled, inviting typing that cannot lead anywhere (Generate is disabled, with no reason given; see I12).
- HIG, Buttons: "use a button that has a prominent visual style for the most likely action in a view … Keep the number of prominent buttons to one or two per view."
- HIG, Onboarding: "Don't let large downloads hinder onboarding … People want to start using your app … immediately."
- Comparison: DiffusionBee 1.5.1 downloads its model on first launch with no choice. Image Playground opens straight to an image. mlx-create asks for three decisions before the first download. See README, Comparable apps.

## Current behavior

`EmptyModelsView` stacks, top to bottom, with `VStack(spacing: 12)`:

1. `Image(systemName: "shippingbox")` at 40 pt, `.secondary`.
2. `Text("No image models installed")`, `.title3.bold()`.
3. `Text("Browse the models that fit this Mac. Each one asks you to accept its license before it downloads.")`, `.callout`, `.secondary`.
4. When `model.browser.recommendedRow` is non-nil: a card (`.quaternary.opacity(0.5)`, radius 10, max width 520) with "Recommended for this Mac" and an `InstallRow`, whose action button reads `Install`.
5. `Button("Browse models")`, `.controlSize(.large)`, which becomes the default action only when there is no recommendation.
6. When `EnhancerOffer.isOffered(model.enhancer)`: an explanatory line and `Button("Get the prompt enhancer")`.

## Target behavior

With a recommendation that can be installed (`recommendedRow?.action == .install`):

```
                    [arrow.down.circle, 44 pt, .secondary]
                 Download a model to start            (.title2.bold())
     mlx-create makes images on this Mac. It needs one image model first.   (.body, .primary)

   ┌──────────────────────────────────────────────────────────────────┐
   │ Qwen-Image 2.1 Turbo                          [ Download… ]      │  ← .borderedProminent, .controlSize(.large),
   │ Recommended for this Mac · 10.55 GB download                     │    keyboardShortcut(.defaultAction)
   └──────────────────────────────────────────────────────────────────┘
                     Choose a Different Model…        (.buttonStyle(.link))
```

- The card's background is `.quaternary.opacity(0.5)` with corner radius 10, padding 16, and maximum width 520 (unchanged values).
- Title line: `Text(row.title)`, `.headline`. Second line: `Text("Recommended for this Mac · \(model.downloadBytes.formatted(.byteCount(style: .file))) download")`, `.callout`, `.primary`.
- `Download…` calls `model.browser.beginInstall(row.id)`. That shows the license sheet first, as today (D20). The ellipsis is there because a sheet follows (HIG, Buttons).
- The enhancer offer is removed from this view. It stays reachable through the Enhance button (`EnhancerInstallSheet`) and the model browser's "Optional extra" section.
- While the recommended row is installing (`row.state` is `.installing`), the card shows the existing `InstallRow(row: row, browser: model.browser)` in place of the title, facts and Download button. I01 then improves what that row shows.

When the recommended row exists but its action is not `.install` (resume, retry or cancel), the card shows `InstallRow` as today, so Resume and Retry keep working.

When there is no recommendation (`recommendedRow == nil`), show only the symbol, the title, the body line, and `Button("Browse Models…")` with `.borderedProminent`, `.controlSize(.large)` and `.keyboardShortcut(.defaultAction)`.

Controls on this canvas at rest: at most 2 buttons (Download…, Choose a Different Model…).

## Edit steps

1. Open `Sources/MCApp/EmptyModelsView.swift`.
2. Inside `body`'s top-level `VStack(spacing: 12)`, replace the `Image(systemName: "shippingbox")` line with `Image(systemName: "arrow.down.circle")` and set `.font(.system(size: 44))`. Keep `.foregroundStyle(.secondary)` and `.accessibilityHidden(true)`.
3. Replace `Text("No image models installed")` and its modifier with `Text("Download a model to start").font(.title2.bold())`.
4. Replace the "Browse the models that fit this Mac…" text with `Text("mlx-create makes images on this Mac. It needs one image model first.").font(.body).multilineTextAlignment(.center)`. Remove its `.foregroundStyle(.secondary)`.
5. Replace the `if let recommended = model.browser.recommendedRow { … }` block and the `Button("Browse models") …` block with the following:

   ```swift
   if let recommended = model.browser.recommendedRow {
       RecommendedInstallCard(row: recommended, browser: model.browser)
       Button("Choose a Different Model…") {
           model.openBrowser()
       }
       .buttonStyle(.link)
   } else {
       Button("Browse Models…") {
           model.openBrowser()
       }
       .buttonStyle(.borderedProminent)
       .controlSize(.large)
       .keyboardShortcut(.defaultAction)
   }
   ```

6. Delete the whole `if EnhancerOffer.isOffered(model.enhancer) { … }` block from this view. Do not delete `EnhancerOffer` itself: `ModelBrowserView` still uses it.
7. Add this private view at the bottom of the file:

   ```swift
   /// The recommended model with its one action (D42). A row that is installing, interrupted or failed falls back to
   /// `InstallRow`, which owns progress, Cancel, Resume and Retry.
   private struct RecommendedInstallCard: View {
       let row: ModelBrowserRow
       let browser: ModelBrowserModel

       var body: some View {
           Group {
               if row.action == .install, let catalogModel = row.model {
                   HStack(alignment: .center, spacing: 12) {
                       VStack(alignment: .leading, spacing: 4) {
                           Text(row.title)
                               .font(.headline)
                           Text(
                               "Recommended for this Mac · \(catalogModel.downloadBytes.formatted(.byteCount(style: .file))) download"
                           )
                           .font(.callout)
                       }
                       Spacer(minLength: 12)
                       Button("Download…") {
                           browser.beginInstall(row.id)
                       }
                       .buttonStyle(.borderedProminent)
                       .controlSize(.large)
                       .keyboardShortcut(.defaultAction)
                       .disabled(!row.canAct)
                   }
               } else {
                   InstallRow(row: row, browser: browser)
               }
           }
           .padding(16)
           .frame(maxWidth: 520)
           .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
       }
   }
   ```

8. Check that `ModelBrowserRow.Action` is `Equatable`. `row.action == .install` must compile; `EnhancerInstallSheet` already compares `row.action == .resume`, so it is.
9. Leave the `.task { … }`, `.sheet(isPresented: licensePresented)` and `licensePresented` code exactly as it is.
10. Format the file: `swift format format --in-place --configuration .swift-format Sources/MCApp/EmptyModelsView.swift`.

## Do not touch

- `LicenseSheet`, `ModelBrowserModel.beginInstall`, `InstallRow`, and the license-before-download order (D20, D26).
- `ModelBrowserView`, including its enhancer section.
- `CanvasView` and `CanvasMode`.
- The smoke tests: they launch with a model installed and never see this view.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s). If it runs past 2 minutes, run `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun suite by suite with `--filter`.
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.

Screenshot and accessibility checks, with `docs/design-audit/capture-kit.md`, an empty home (`launch.sh /tmp/s01-empty`) and the window at 1100×692 (`cap.py small`):

5. In `ax dump`, the canvas group (the `AXGroup/AXHostingView` between the two `AXSplitter`s) contains exactly one `AXButton` whose `desc` starts with `Download` and exactly one more `AXButton` (`Choose a Different Model…`). No element's `desc` or `value` contains `prompt enhancer`.
6. The Download button frame lies fully inside the window frame, so it is visible without scrolling at 1100×640 content size.
7. `cap.py shot` in light and dark mode: the Download button has the accent-coloured fill and is the only accent-filled control in the canvas. Save the shots as `S01_small_light.png` and `S01_small_dark.png` and attach them to the PR.
8. Pressing Return with the window focused opens the license sheet. Check: `osascript -e 'tell application "System Events" to key code 36'`, then `ax dump` shows an `AXSheet` whose text includes "License".

No XCUITest: D50 keeps the first-launch state out of the smoke suite.

## Resolution

Done on branch `feat/audit-first-run-path`, commit `c29cd21` (PR pending). The edit steps describe the as-built change. Exercised: `swift build`, `swift test`, `swift format lint --strict`, the Debug `xcodebuild`, GUI smoke (exit 0), and acceptance checks 5 to 8 on an empty home. `ax dump` shows one `Download…` button and one `Choose a Different Model…` link, no "prompt enhancer" text, and the Download button frame inside the window. Return opens the licence sheet. A vision-agent read of `S01_small_light.png` confirmed one accent-filled control (`#3478F6`) and no shippingbox. `S01_small_dark.png` confirms layout and legibility, but the capture window was not key, so the accent fill itself is only verified in light mode and on the dark licence sheet.
