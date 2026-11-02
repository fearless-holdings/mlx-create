# I12 · Generate: when it is disabled, say why

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 2, minor: on first launch the 300 pt prompt invites typing, Generate stays disabled, and nothing says a model is missing or downloading. In dark mode the disabled button is a solid blue (#095DBA) that reads as enabled |
| Frequency | Every first launch; whenever the prompt is empty or the engine is down |
| Heuristics | H1 Visibility of system status; H9 Help users recognize … errors; H5 Error prevention |
| User task | (a) first launch to first kept image |
| Strategy metric | Time to first kept image |
| HLD decisions | No D* change |
| Size | S |
| Depends on | none |

## Evidence

- Screenshots: `screens/01-first-launch-empty_small_light.png` and `_small_dark.png`. Generate is disabled with no explanation. `screens/02b-model-downloading-main_small_light.png` shows the same during a download.
- Measured (capture kit): the disabled Generate fill is #4FA3FF with label #A7D1FF in light mode (label contrast 1.65:1), and #095DBA with label #84AEDD in dark mode. The enabled fill is #007AFF with a white label (4.02:1). In dark mode the disabled state differs from the enabled one mostly by shade.
- Code: `Sources/MCApp/GenerationPanel.swift`, `bottomRow` (`.disabled(!model.canGenerate)`, no hint). `Sources/MCApp/AppModel.swift`, `canGenerate`.
- HIG, Buttons (macOS): when a button is unavailable, people need a way to understand why; the help tag and nearby text are the standard places.

## Target behavior

When `canGenerate` is false, the space left of Generate (where the estimate shows today) shows one line, `.callout`, `.primary`, `lineLimit(2)`. The first matching reason wins:

1. No image model installed and a download is running: "Waiting for \(title) to download".
2. No image model installed: "Download a model to start".
3. Models installed, none selectable: "Choose a model to start".
4. Engine failed: "The image engine isn't running".
5. Prompt empty: "Type a prompt to generate".

The same text is Generate's `.accessibilityHint` and `.help`. When `canGenerate` is true, the estimate shows as today.

## Edit steps

1. `Sources/MCApp/AppModel.swift`, next to `canGenerate`, add:

   ```swift
   /// Why Generate is disabled, or nil when it is enabled (I12). Ordered so the first step the user can take comes first.
   var generateBlockReason: String? {
       if models.isEmpty {
           if let installing = browser.installingRow { return "Waiting for \(installing.title) to download" }
           return "Download a model to start"
       }
       guard let model = selectedModel, ModelSelection.isSelectable(model) else { return "Choose a model to start" }
       if engineFailed { return "The image engine isn't running" }
       if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Type a prompt to generate" }
       return nil
   }
   ```

   `browser.installingRow` comes from I01. If I01 is not merged, add this to `ModelBrowserModel`:
   `var installingRow: ModelBrowserRow? { rows.first { if case .installing = $0.state { true } else { false } } }`.
2. `Sources/MCApp/GenerationPanel.swift`, `bottomRow`: replace

   ```swift
   if let estimate {
       Text(SpeedEstimate.scaled(estimate, by: model.batchCount).label)
           …
   }
   ```

   with

   ```swift
   if let reason = model.generateBlockReason {
       Text(reason)
           .font(.callout)
           .lineLimit(2)
           .fixedSize(horizontal: false, vertical: true)
   } else if let estimate {
       Text(SpeedEstimate.scaled(estimate, by: model.batchCount).label)
           .font(.caption)
           .foregroundStyle(.secondary)
   }
   ```

   On `Button("Generate")`, add `.help(model.generateBlockReason ?? "Generate (⌘↩)")` and `.accessibilityHint(model.generateBlockReason ?? "")`. If S05 already added a `.help`, replace it with this one.
3. Test, `Tests/MCAppTests/GenerateBlockReasonTests.swift` (pattern: `AppHarness.make()`, `start()`, `refreshModels()`):
   - With a model and a prompt, `generateBlockReason == nil` and `canGenerate == true`.
   - With an empty prompt, it is non-nil and `canGenerate == false`.
   - `canGenerate == (generateBlockReason == nil)` holds in both cases. This keeps the two in agreement; do not compare wording.
4. Format the touched files.

## Do not touch

- `canGenerate` itself (the smoke suite checks `generateButton.isEnabled`).
- `lastError` and its red line under the row (V02 restyles it).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including `GenerateBlockReasonTests` (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0.

With the capture kit:

6. Empty home: `ax dump` shows `AXStaticText` "Download a model to start" in the left panel's bottom row, and the Generate button's `help` equals it.
7. One model, empty prompt: the text reads "Type a prompt to generate". After `ax setvalue … "a teapot"` it is gone, and the estimate or nothing shows instead.
8. `contrast.py` on the reason text in light and dark captures: ≥ 4.5:1. Attach `I12_small_light.png` and `I12_small_dark.png`.

## Resolution

Done on branch `feat/audit-first-run-path`, commit `adc7695` (PR [#26](https://github.com/fearless-holdings/mlx-create/pull/26)). Differs from the edit steps in one place: `generateBlockReason` lives in `Sources/MCApp/AppModel+GenerateBlockReason.swift`, not in `AppModel.swift`, which was already at the file-size budget the pre-commit check enforces. `browser.installingRow` comes from the I01 commit `8ed5201`, which therefore precedes this one. Exercised: `swift build`, `swift test` (including `GenerateBlockReasonTests`), `swift format lint --strict`, the Debug `xcodebuild`, GUI smoke (exit 0), and checks 6 to 8. Empty home: "Download a model to start" in the bottom row, and the Generate button's `help` equals it. One model installed: empty prompt reads "Type a prompt to generate"; after `ax setvalue` of "a teapot" the reason is gone and Generate is enabled. `contrast.py` on the reason text gives 14.94:1 in light and 11.99:1 in dark. The vision read confirmed it wraps to two lines and does not collide with the stepper or Generate. While a download runs, the reason reads "Waiting for <model> to download", and it wraps mid-name in the narrow left panel.
