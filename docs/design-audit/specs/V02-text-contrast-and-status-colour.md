# V02 · Status and error text: readable size, ≥ 4.5:1 contrast, colour on the symbol only

| | |
|---|---|
| Tag | VISUAL |
| Severity (Nielsen 0–4) | 2, minor: failure reasons and errors are the text users most need, and they are the smallest and lowest-contrast text in the app |
| Frequency | Every error, every status line |
| Heuristics | H9 Help users recognize … errors; accessibility (WCAG 1.4.3 Contrast) |
| User task | (e) recover from errors; (d) LoRA fit reasons |
| Strategy metric | Failed generation rate (people act on errors they can read) |
| HLD decisions | No D* change |
| Size | M |
| Depends on | V01 (tokens). Do it after I03, I05 and I06, which rewrite the failure, queue and banner text; this spec then covers what remains |

## Evidence

Measured with the capture kit (`contrast.py`, 1x captures, so the true ratio is at least the figure shown):

| Text | Light | Dark |
|---|---|---|
| `.red` error in the enhance card (`08-enhancer-memory-refusal_*`) | **3.57:1** | 4.86:1 |
| `.red` "Failed" on the `.quaternary` queue cell (`04c-queue-cancelled_small_light`, `08b-oom-failed-job_small_dark`) | **2.86:1** | **3.62:1** |
| `.secondary` caption on `.quaternary` ("0 of 6 saved", failure text in the cell) | **3.80:1** | 4.92:1 |
| `.secondary` on the window background (canvas hint, browser facts line, placeholder) | **3.95:1** | 5.87–5.92:1 |
| Engine banner, `.primary` on the red 12 % tint | 13.21:1 | 10.44:1 |

- WCAG AA asks for 4.5:1 for text under 18 pt (14 pt bold). HIG, Accessibility: "Strive to meet color contrast minimum standards … [Accessibility Inspector] uses the following values from WCAG Level AA." `.secondary` on white is a system colour Apple uses for supplementary text; the problem here is that essential text uses it, and that red is used for text at all.
- Inventory (V01): `.foregroundStyle(.red)` on text ×10, `Color.red` ×1 (`LoRASection`), `.orange` ×3, `.green` ×1; 66 uses of 10 pt type, including every failure reason.

## Target behavior

- **Rule 1.** Errors, warnings and successes are shown as an SF Symbol in the tone colour plus text in `.primary`, at `.mcSupporting` (12 pt). Text is never red, orange or green.
- **Rule 2.** Reasons and status lines (why something is disabled, why a LoRA does not fit, enhance captions) use `.mcSupporting` and `.primary`.
- **Rule 3.** `.secondary` stays only for supplementary metadata that repeats information shown elsewhere (sizes, counts, dates, "by creator", the facts line) and for placeholders.
- Symbols: critical `exclamationmark.triangle.fill` (`MCTone.critical`); warning `exclamationmark.circle.fill` (`MCTone.warning`); success `checkmark.circle.fill` (`MCTone.success`).

## Edit steps

1. Create `Sources/MCApp/Design/MCStatusText.swift`:

   ```swift
   import SwiftUI

   /// A status line: a coloured symbol and primary text (V02). The colour is on the symbol only, so the text keeps
   /// full contrast in light, dark and Increase Contrast.
   struct MCStatusText: View {
       enum Kind { case critical, warning, success }
       let kind: Kind
       let text: String

       init(_ kind: Kind, _ text: String) {
           self.kind = kind
           self.text = text
       }

       var body: some View {
           HStack(alignment: .firstTextBaseline, spacing: MCSpacing.tight) {
               Image(systemName: symbol)
                   .foregroundStyle(tone)
                   .accessibilityHidden(true)
               Text(text)
                   .foregroundStyle(.primary)
                   .fixedSize(horizontal: false, vertical: true)
           }
           .font(.mcSupporting)
           .accessibilityElement(children: .combine)
       }

       private var symbol: String {
           switch kind {
           case .critical: "exclamationmark.triangle.fill"
           case .warning: "exclamationmark.circle.fill"
           case .success: "checkmark.circle.fill"
           }
       }

       private var tone: Color {
           switch kind {
           case .critical: MCTone.critical
           case .warning: MCTone.warning
           case .success: MCTone.success
           }
       }
   }
   ```

2. Replace these call sites (V01 swapped the red, orange and green literals for `MCTone`, so find each with `rg -n 'foregroundStyle\(MCTone\.(critical|warning|success)\)|MCTone\.(critical|warning|success)' Sources/MCApp`):
   - `GenerationPanel.bottomRow`, `if let error = model.lastError`: `MCStatusText(.critical, error)`.
   - `EnhanceResultCard.content`, `.failed(let message)`: `MCStatusText(.critical, message)`.
   - `EnhancerInstallSheet.content`, `.failed(let message, _)`: `MCStatusText(.critical, message)`.
   - `InstallRow.stateView`, `.failed(let message)`: `MCStatusText(.critical, message)`. `InstallRow`'s `fitWarning` `Label(…).foregroundStyle(.orange)` becomes `MCStatusText(.warning, warning)`.
   - `ShelfRowView.trailing`, `.failed(let message)`: `MCStatusText(.critical, message)` (keep `.lineLimit(2)` on it).
   - `CivitaiResultRowView.statusView`: `.added` → `MCStatusText(.success, "Added to your LoRAs")` (or the S08 text); `.needsKey` → `MCStatusText(.warning, "Needs a Civitai key to download")`; `.refused(let reason)` and `.failed(let text)` → `MCStatusText(.critical, …)`.
   - `CivitaiKeyField`, `if let error = browse.keyError`: `MCStatusText(.critical, error)`.
   - `CollectionNameSheet`, `if let errorMessage`: `MCStatusText(.critical, errorMessage)`.
   - `LoRARowView.summary`, `if let reason = row.fit.reason`: `row.fit == .fileMissing ? MCStatusText(.critical, reason) : MCStatusText(.warning, reason)`.
   - `QueueStripView.JobCell.statusContent` `.failed`, if I05 has not already done it: the symbol `.red`, the text `.primary`.
3. Promote reasons from `.mcMetadata` (V01 moved the `.caption` reasons and metadata there, keeping them 10 pt, and left badge text on `.mcBadge`) to `.mcSupporting` and `.primary`. Remove `.foregroundStyle(.secondary)` at:
   - `GenerationPanel.enhanceRow` (the caption and the reload note);
   - `LoRASection` ("None of these will be used.", `loraNotice`, the memory hint);
   - `LoRALibraryRow` `addBlockReason` and "File missing";
   - `ShelfView` "Trigger words: …" stays metadata: keep it `.secondary`, but at `.mcSupporting`.
4. Leave `.secondary` where the text repeats information: the `InstallRow` facts line, `CivitaiResultRowView.detailLine`, LoRA sizes, the gallery status line, placeholders, and the canvas empty hint (`.title3`, large text, where 3:1 applies).
5. Format the touched files.

## Do not touch

- System controls' own colours (the accent button, segmented controls).
- `EngineStatusBanner` (already ≥ 10:1; I06 edits its copy).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0.
6. `rg -n 'foregroundStyle\(MCTone\.(critical|warning|success)\)' Sources/MCApp` may list only `Image(systemName:)` lines (inspect each hit), and `rg -n 'Text\([^)]*\)[^\n]*\n?[^\n]*foregroundStyle\(MCTone\.' --multiline Sources/MCApp` prints nothing.

With the capture kit:

7. Collection name sheet: press Create with an empty name before S04 lands, or enter a duplicate name after it. The error line's text measures ≥ 4.5:1 (`contrast.py` on its text box, light and dark).
8. Enhance with the enhancer not runnable (or engine memory refused): the failure card text measures ≥ 4.5:1 in light and dark.
9. Attach `V02_name_error_light.png` and `V02_name_error_dark.png`.

## Resolution

Done in [#45](https://github.com/fearless-holdings/mlx-create/pull/45). The change follows the edit steps. `Sources/MCApp/Design/MCStatusText.swift` is the spec's component; every named call site uses it, and no `Text` carries an `MCTone` status colour. Enhance captions, LoRA notices and LoRA add-block reasons moved to `.mcSupporting`/`.primary`; sizes, counts, dates, trigger words, the facts line and placeholders stay `.secondary`.

Exercised: `swift build`; `swift test` (296 tests in 31 suites); whole-tree `swift format lint --strict`; `git diff --check`; `xcodegen generate` + Debug `xcodebuild` (`BUILD SUCCEEDED`); the spec's two `rg` checks.

Manual acceptance on 2026-11-10: the Debug build was launched on the real library and the author inspected the changed status lines and approved them.

Not exercised: the automated GUI smoke (the run at `build/gui-smoke/20261110-145911/` lost its connection to the app while the Mac was busy with other tasks, so it is not a pass), and the capture-kit contrast measurements and light/dark captures (acceptance 7–9), for the same reason. The changed text is `.primary`, so the audit's pre-change red and `.secondary` measurements do not carry over.
