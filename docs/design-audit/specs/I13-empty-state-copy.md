# I13 · Empty states that match the state

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 1, cosmetic: small contradictions on the first screens ("Queue empty" with no model; "Type a prompt" with a prompt already typed) |
| Frequency | First run and every new collection |
| Heuristics | H1 Visibility of system status; H2 Match between system and the real world |
| User task | (a) first image, (f) change collection |
| Strategy metric | Nothing to learn |
| HLD decisions | No D* change. HLD §10: the queue strip is hidden in `.noModels`, `.onlyUnavailable` and `.emptyHint`, unless calibration is running or the queue holds any job |
| Size | S |
| Depends on | none |

## Evidence

- `screens/01-first-launch-empty_small_light.png`: no model is installed, yet the queue strip says "Queue empty".
- `screens/16c-new-collection-empty_small_light.png`: a prompt is typed, and the canvas says "Type a prompt and press ⌘↩".
- `screens/03a-ready-empty-hint_small_light.png` and `screens/06-populated-gallery_small_light.png`: the gallery's empty state is "No images yet", `.secondary`, centred in the 260 pt column.
- Code: `Sources/MCApp/MainWindow.swift` shows `QueueStripView` when `model.canvasMode != .emptyHint || model.queueHeader == .calibrating`, which includes `.noModels` and `.onlyUnavailable`. `Sources/MCApp/CanvasView.swift`, `.emptyHint` case: a fixed `Text("Type a prompt and press ⌘↩")`. `Sources/MCApp/GalleryView.swift`, `content`.

## Target behavior

- The queue strip is hidden in `.noModels`, `.onlyUnavailable` and `.emptyHint`, unless calibration is running or the queue holds any job, whatever its status (queued, running, paused, failed, cancelled): a job the user can still cancel, resume or retry keeps its strip.
- Canvas `.emptyHint`, `.title3`, `.secondary` (large text, so the secondary colour is acceptable):
  - prompt empty: "Describe an image on the left, then press ⌘↩";
  - prompt not empty: "Press ⌘↩ to make your first image".
- Gallery empty state: "Your images will appear here" (`.callout`, `.secondary`), unchanged position.

## Edit steps

1. `Sources/MCApp/MainWindow.swift`: replace the condition `if model.canvasMode != .emptyHint || model.queueHeader == .calibrating {` with `if model.showsQueueStrip {` and add to `AppModel` beside `canvasMode`:

   ```swift
   /// Whether the queue strip is visible (HLD §10). It is hidden while the canvas offers nothing to act on, but a job of
   /// any status keeps it: a queued, paused or failed job still offers Cancel, Resume or Retry.
   public var showsQueueStrip: Bool {
       if queueHeader == .calibrating || !queueJobs.isEmpty { return true }
       return canvasMode == .content
   }
   ```

   A job of any status keeps the strip, so a queued, paused or failed job is never hidden; calibrating and `.content` keep it too.

2. `Sources/MCApp/AppModel.swift`: add `emptyHintText` beside `showsQueueStrip`:

   ```swift
   /// The empty canvas's hint: it asks for a prompt only while the prompt is empty.
   public var emptyHintText: String {
       prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           ? "Describe an image on the left, then press ⌘↩"
           : "Press ⌘↩ to make your first image"
   }
   ```

   `Sources/MCApp/CanvasView.swift`, `.emptyHint` case: replace `Text("Type a prompt and press ⌘↩")` with `Text(model.emptyHintText)`. Keep `.font(.title3)`, `.foregroundStyle(.secondary)` and the frame.
3. `Sources/MCApp/GalleryView.swift`, `content`: change `Text("No images yet")` to `Text("Your images will appear here")` and add `.font(.callout)`.
4. Tests: in `Tests/MCAppTests/AppModelTests.swift`, add `theStripIsHiddenUntilThereIsSomethingToShow`, which covers no models with an empty queue, a model with an empty queue and gallery, a saved image, and a queued, paused and failed job with no models, plus calibration with nothing queued; and `theEmptyHintFollowsThePrompt`, which covers an empty prompt, a whitespace-only prompt and a prompt with text. Use `AppHarness.make(...)` as the existing no-models tests do (`rg -n "noModels" Tests/MCAppTests`).
5. Format the touched files.

## Do not touch

- `CanvasMode` cases and their selection logic.
- The calibration header (D48).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0.
6. `swift test --filter theStripIsHiddenUntilThereIsSomethingToShow` passes: it proves the strip is gone from an empty home and an empty canvas, and stays for a saved image, any queued, paused or failed job, and calibration.
7. `swift test --filter theEmptyHintFollowsThePrompt` passes: it proves the canvas hint asks for a prompt only while the prompt is empty.
