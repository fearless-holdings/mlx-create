# I01 · Downloads: progress and time left stay visible in the main window

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 4, catastrophe: a first-time user who starts a download from the model browser and closes it sees "No image models installed" again, with no sign anything is happening, for the 5–20 minutes a 4–16 GB download takes |
| Frequency | Every model download; on the first-run path for every user |
| Heuristics | H1 Visibility of system status |
| User task | (a) first launch to first kept image, including the download |
| Strategy metric | Time to first kept image (download included) |
| HLD decisions | No D* change |
| Size | M |
| Depends on | S01 (the empty-canvas card). I11 fixes the "Interrupted at" byte count separately |

## Evidence

- Screenshots: `screens/02-model-downloading-browser_small_light.png` (progress shows only inside the browser sheet: "Downloading: 125,6 MB of 4,62 GB", with no time left); `screens/02b-model-downloading-main_small_light.png` (after Done, the main window still says "No image models installed". The recommended card shows a disabled Install with a truncated reason, "FLUX.2 klein 4B is installing. Wait for it t…", and its badges wrap into "Fits this / Mac" and "Recom-/mended").
- Code: `Sources/MCApp/EmptyModelsView.swift` shows only `model.browser.recommendedRow`. `Sources/MCApp/Models/ModelBrowserModel.swift` keeps the active install in `active` (`ModelInstaller.Snapshot.Active`) and applies snapshots in `apply(_:)`. `Sources/MCApp/Models/InstallRow.swift`, `stateView` `.installing` prints phase and bytes only.
- HIG, Progress indicators: "A determinate progress indicator can help people decide whether to do something else while waiting … People generally prefer a determinate progress indicator, because it helps them gauge what's happening and how long it will take." HIG, Loading: "Clearly communicate that content is loading and how long it might take to complete."

## Current behavior

Install progress (fraction and bytes) is visible only in the row of the model being installed, which appears in the model browser sheet. It also appears in the empty-canvas card, but only when that model happens to be the recommended one.

## Target behavior

- **Time left.** Every installing row shows, under the bar: `"\(phase): \(done) of \(total) · \(remaining)"`, where `remaining` is one of:
  - "Less than a minute left" (under 60 s);
  - "About N min left" (under 60 min, N rounded up);
  - "About H h M min left".
  The text is omitted until at least 5 s of samples exist, and while the phase is not `.downloading`.
- **Empty canvas.** When any install is active, the empty-canvas card shows that install, whatever model it is. Its title is `"Downloading \(row.title)"` (`.headline`), followed by the `InstallRow` progress and its Cancel button. This replaces the recommended card while it lasts.
- **Model chip popover** (when models already exist): above "Browse models…", a non-interactive row reads `"Downloading \(title) · \(percent)% · \(remaining)"` with a `ProgressView(value:)` of width 220.

## Edit steps

1. Create `Sources/MCApp/Models/InstallRateEstimator.swift`:

   ```swift
   import Foundation

   /// Time left for a download from recent byte counts (docs/design-audit/specs/I01). Pure, so tests feed it samples.
   struct InstallRateEstimator {
       private(set) var samples: [(at: Date, bytes: Int64)] = []
       static let window: TimeInterval = 20
       static let minimumSpan: TimeInterval = 5

       mutating func record(bytes: Int64, at date: Date) {
           if let last = samples.last, bytes < last.bytes { samples.removeAll() }  // a restart or a new file set
           samples.append((date, bytes))
           samples.removeAll { date.timeIntervalSince($0.at) > Self.window }
       }

       /// Seconds left, or nil until `minimumSpan` of samples with progress exist.
       func secondsLeft(total: Int64) -> Double? {
           guard let first = samples.first, let last = samples.last else { return nil }
           let span = last.at.timeIntervalSince(first.at)
           let gained = Double(last.bytes - first.bytes)
           guard span >= Self.minimumSpan, gained > 0 else { return nil }
           return Double(max(0, total - last.bytes)) / (gained / span)
       }

       static func text(secondsLeft: Double) -> String {
           if secondsLeft < 60 { return "Less than a minute left" }
           let minutes = Int((secondsLeft / 60).rounded(.up))
           if minutes < 60 { return "About \(minutes) min left" }
           return "About \(minutes / 60) h \(minutes % 60) min left"
       }
   }
   ```

2. In `ModelBrowserModel`:
   - Add `private(set) var rate = InstallRateEstimator()` and `private var rateModelID: String?`.
   - In `private func apply(_ snapshot: ModelInstaller.Snapshot)`, after `active = snapshot.active`, add:

     ```swift
     if let active = snapshot.active {
         if rateModelID != active.modelID {
             rate = InstallRateEstimator()
             rateModelID = active.modelID
         }
         rate.record(bytes: active.event.bytesDone, at: Date())
     } else {
         rate = InstallRateEstimator()
         rateModelID = nil
     }
     ```

   - Add:

     ```swift
     /// "About 4 min left" for the active download, or nil while unknown (I01).
     func remainingText(for modelID: String) -> String? {
         guard let active, active.modelID == modelID, active.event.phase == .downloading,
             let seconds = rate.secondsLeft(total: active.event.bytesTotal)
         else { return nil }
         return InstallRateEstimator.text(secondsLeft: seconds)
     }

     /// The row being installed now, if any.
     var installingRow: ModelBrowserRow? {
         rows.first { if case .installing = $0.state { true } else { false } }
     }
     ```

3. `Sources/MCApp/Models/InstallRow.swift`, in `stateView`'s `.installing(let progress)` case: change the `Text` to

   ```swift
   Text(
       [
           "\(Self.phaseLabel(progress.phase)): \(bytes(progress.bytesDone)) of \(bytes(progress.bytesTotal))",
           browser.remainingText(for: row.id),
       ].compactMap { $0 }.joined(separator: " · ")
   )
   ```

4. `Sources/MCApp/EmptyModelsView.swift` (after S01): before the `if let recommended = model.browser.recommendedRow` branch, add a branch that takes priority:

   ```swift
   if let installing = model.browser.installingRow {
       VStack(alignment: .leading, spacing: 8) {
           Text("Downloading \(installing.title)")
               .font(.headline)
           InstallRow(row: installing, browser: model.browser)
       }
       .padding(16)
       .frame(maxWidth: 520)
       .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
   } else if let recommended = model.browser.recommendedRow {
   ```

   Keep the existing recommended branch and `else` as its continuation. If S01 is not merged yet, put the same block before the existing `if let recommended` card.
5. `Sources/MCApp/ModelChip.swift`, in `modelList`, just before the last `Divider()` that precedes "Browse models…", add:

   ```swift
   if let installing = model.browser.installingRow, case .installing(let progress) = installing.state {
       Divider().padding(.vertical, 4)
       VStack(alignment: .leading, spacing: 4) {
           Text(
               ["Downloading \(installing.title) · \(Int(progress.fraction * 100))%", model.browser.remainingText(for: installing.id)]
                   .compactMap { $0 }.joined(separator: " · ")
           )
           .font(.callout)
           ProgressView(value: progress.fraction)
               .frame(width: 220)
       }
       .padding(.horizontal, 6)
       .padding(.vertical, 4)
       .accessibilityElement(children: .combine)
   }
   ```

6. Add `Tests/MCAppTests/InstallRateEstimatorTests.swift` (Swift Testing, `@testable import MCApp`):
   - No estimate with one sample, or with a span under 5 s.
   - Samples at t = 0 s / 0 bytes and t = 10 s / 100 MB with a 1100 MB total give `secondsLeft` of 100 ± 1.
   - A byte count that goes down clears the samples, giving nil.
   - `text(secondsLeft:)` returns different strings for 30, 600 and 7200 s. Assert they are distinct, not their exact wording.
7. Format the touched files.

## Do not touch

- `ModelInstaller`, `ModelDownloader` and the staging and verification rules (D27).
- The license-before-download order (D20).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including `InstallRateEstimatorTests` (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.

With the capture kit and an empty home. This downloads real weights: **ask the user before running it**, start the smallest model (FLUX.2 klein 4B), and cancel within 60 s.

5. Start the install from the browser, wait 10 s, close the browser (Done). In `ax dump`, the canvas shows a static text starting "Downloading FLUX.2 klein 4B" and a static text containing "min left" or "Less than a minute left".
6. Capture `I01_main_small_light.png` showing the bar in the main window, then cancel the install with the card's Cancel button and delete the throwaway home.
