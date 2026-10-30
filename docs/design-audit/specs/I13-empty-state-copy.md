# I13 · Empty states that match the state

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 1, cosmetic: small contradictions on the first screens ("Queue empty" with no model; "Type a prompt" with a prompt already typed) |
| Frequency | First run and every new collection |
| Heuristics | H1 Visibility of system status; H2 Match between system and the real world |
| User task | (a) first image, (f) change collection |
| Strategy metric | Nothing to learn |
| HLD decisions | No D* change. HLD §10: the queue strip is "Hidden while the canvas shows the empty hint" |
| Size | S |
| Depends on | none |

## Evidence

- `screens/01-first-launch-empty_small_light.png`: no model is installed, yet the queue strip says "Queue empty".
- `screens/16c-new-collection-empty_small_light.png`: a prompt is typed, and the canvas says "Type a prompt and press ⌘↩".
- `screens/03a-ready-empty-hint_small_light.png` and `screens/06-populated-gallery_small_light.png`: the gallery's empty state is "No images yet", `.secondary`, centred in the 260 pt column.
- Code: `Sources/MCApp/MainWindow.swift` shows `QueueStripView` when `model.canvasMode != .emptyHint || model.queueHeader == .calibrating`, which includes `.noModels` and `.onlyUnavailable`. `Sources/MCApp/CanvasView.swift`, `.emptyHint` case: a fixed `Text("Type a prompt and press ⌘↩")`. `Sources/MCApp/GalleryView.swift`, `content`.

## Target behavior

- The queue strip is hidden in `.noModels`, `.onlyUnavailable` and `.emptyHint`, unless calibration is running (that exception exists today).
- Canvas `.emptyHint`, `.title3`, `.secondary` (large text, so the secondary colour is acceptable):
  - prompt empty: "Describe an image on the left, then press ⌘↩";
  - prompt not empty: "Press ⌘↩ to make your first image".
- Gallery empty state: "Your images will appear here" (`.callout`, `.secondary`), unchanged position.

## Edit steps

1. `Sources/MCApp/MainWindow.swift`: replace the condition `if model.canvasMode != .emptyHint || model.queueHeader == .calibrating {` with `if model.showsQueueStrip {` and add to `AppModel` (in `AppModel+Projection.swift` or `ViewState.swift` as an extension):

   ```swift
   /// The strip shows once the canvas has something to show, or while calibration runs (HLD §10, I13).
   var showsQueueStrip: Bool {
       if queueHeader == .calibrating { return true }
       switch canvasMode {
       case .content: return true
       case .noModels, .onlyUnavailable, .emptyHint: return false
       }
   }
   ```

2. `Sources/MCApp/CanvasView.swift`, `.emptyHint` case: replace `Text("Type a prompt and press ⌘↩")` with

   ```swift
   Text(
       model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           ? "Describe an image on the left, then press ⌘↩" : "Press ⌘↩ to make your first image")
   ```

   Keep `.font(.title3)`, `.foregroundStyle(.secondary)` and the frame.
3. `Sources/MCApp/GalleryView.swift`, `content`: change `Text("No images yet")` to `Text("Your images will appear here")` and add `.font(.callout)`.
4. Test: in `Tests/MCAppTests/AppModelTests.swift`, add `theStripIsHiddenUntilThereIsSomethingToShow`. Use a harness with no models (`AppHarness.make(...)` with a `FakeEngine` reporting none; see the existing no-models tests: `rg -n "noModels" Tests/MCAppTests`) and expect `showsQueueStrip == false`. With a model and no images it is also false. After one generation it is true.
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

With the capture kit:

6. Empty home: `ax dump` contains no `AXStaticText` "Queue empty".
7. One model, no images, prompt "a teapot" set with `ax setvalue`: the canvas text reads "Press ⌘↩ to make your first image".
