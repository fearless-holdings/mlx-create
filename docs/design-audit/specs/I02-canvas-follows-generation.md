# I02 · Canvas: keep the last image while the next one runs, and show every new image

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 3, major: pressing Generate blanks the canvas ("Select an image in the gallery, or generate one."), and in a batch only the first image ever reaches the canvas |
| Frequency | Every generation |
| Heuristics | H1 Visibility of system status; H3 User control and freedom; H6 Recognition rather than recall |
| User task | (b) tweak a prompt and generate again; (a) first image |
| Strategy metric | Time to first kept image (see each result as it lands, compare it with the last one) |
| HLD decisions | No D* change. HLD §10: "Canvas … the selected result or the live step preview" |
| Size | M |
| Depends on | none (I03 adds a failure panel to the same view; do I02 first) |

## Evidence

- Screenshots: `screens/03b-first-generation-t1_small_light.png` (the job is starting and the canvas tells the user to "generate one"); `screens/04-queue-several-jobs_small_light.png` (four jobs queued: the previous image has left the canvas, which shows the same sentence); `screens/04b-queue-midrun_small_light.png` (six lemon images in the gallery; the canvas shows only a step bar).
- Code: `Sources/MCApp/AppModel.swift`, `generate()` sets `selection = job.id`. `Sources/MCApp/AppModel+Projection.swift`, `prependImage(jobID:id:)` moves the canvas only `if selection == jobID`, so the first saved image of the selected job takes the canvas, the rest of the batch never does, and earlier jobs' images never do. `Sources/MCApp/CanvasView.swift`, `ContentCanvas.body` shows "Select an image in the gallery, or generate one." whenever `selectedImage` and `runningProgress` are both nil, including while a job is starting.
- HIG, Feedback: "Consider integrating status feedback into your interface … near the items it describes."
- Comparison: Image Playground keeps the current image on screen and lets you scroll between versions of one idea. DiffusionBee shows the result where the last one was.

## Current behavior

Generate → canvas empties → "Select an image …" (while starting) → step bar alone → first image of the selected job. Images from the other images of the batch, and from jobs queued earlier, land only in the gallery.

## Target behavior

- After Generate, the canvas keeps showing the image that was there, with the step bar laid over its bottom edge, until a new image is saved.
- Every image saved by a job started with Generate **in this session** becomes the canvas image as it lands, whichever job saved it, unless the user has since clicked a gallery tile or a queue cell. Clicking hands control back to the user until the next Generate.
- While a job is starting (queue running, no step yet) and no image is on the canvas, the canvas shows `ProgressView().controlSize(.small)` plus "Starting…" (`.callout`), never "Select an image in the gallery, or generate one."
- The step bar over an image: `StepProgressView` inside a `.regularMaterial` capsule, 12 pt from the bottom edge of the image area, maximum width 420.

## Edit steps

1. `Sources/MCApp/AppModel.swift`, in `AppModel`, next to `public var selection: UUID?`:

   ```swift
   /// Jobs whose saved images take the canvas as they land (I02). Generate adds its job; a click in the gallery or the
   /// queue strip clears the set, handing the canvas back to the user.
   var canvasFollowedJobs: Set<UUID> = []
   /// The image the canvas keeps showing while a followed job has not saved one yet (I02).
   var canvasFallbackImageID: UUID?
   ```

2. In `generate()`, in the `do` block, replace `selection = job.id` with:

   ```swift
   if let shown = selectedImage?.id { canvasFallbackImageID = shown }
   selection = job.id
   canvasFollowedJobs.insert(job.id)
   ```

3. `Sources/MCApp/AppModel+Projection.swift`, `prependImage(jobID:id:)`: replace `if selection == jobID { selection = imageID }` with:

   ```swift
   if selection == jobID || canvasFollowedJobs.contains(jobID) {
       selection = imageID
       canvasFallbackImageID = imageID
   }
   ```

   Leave the earlier `guard let image else { if selection == jobID { selection = nil } … }` as it is.
4. `Sources/MCApp/AppModel+GalleryActions.swift`, `selectGalleryImage(_:click:)`, in the `.plain` case, add `canvasFollowedJobs.removeAll()`.
5. Add to `AppModel` (in `AppModel+Selection.swift`):

   ```swift
   /// A click on a queue cell: shows that job and stops the canvas following new images (I02).
   func selectJob(_ id: UUID) {
       selection = id
       canvasFollowedJobs.removeAll()
   }

   /// The image the canvas draws: the selection, else the image kept from before the last Generate.
   var canvasImage: LibraryImage? {
       if let selectedImage { return selectedImage }
       guard let canvasFallbackImageID else { return nil }
       return galleryImages.first { $0.id == canvasFallbackImageID }
   }

   /// A job is under way but has sent no step yet.
   var isStartingJob: Bool {
       runningProgress == nil && queueJobs.contains { $0.status == .running || $0.status == .queued }
   }
   ```

   This needs `import MCLibrary` in that file.
6. `Sources/MCApp/QueueStripView.swift`, `JobCell.body`: change the button action `model.selection = job.id` to `model.selectJob(job.id)`.
7. `Sources/MCApp/AppModel+Collections.swift`, in the function that applies a collection switch (`showCollection(_:)`): add `canvasFollowedJobs.removeAll()` and `canvasFallbackImageID = nil` where `selection` is reset.
8. `Sources/MCApp/CanvasView.swift`, replace `ContentCanvas.body` with:

   ```swift
   var body: some View {
       VStack(spacing: 12) {
           if let image = model.canvasImage {
               SelectedImageView(model: model, image: image)
                   .id(image.id)
                   .overlay(alignment: .bottom) {
                       if let progress = model.runningProgress {
                           StepProgressView(progress: progress)
                               .padding(.horizontal, 14)
                               .padding(.vertical, 8)
                               .frame(maxWidth: 420)
                               .background(.regularMaterial, in: Capsule())
                               .padding(.bottom, 12)
                       }
                   }
           } else if let progress = model.runningProgress {
               StepProgressView(progress: progress)
                   .frame(maxWidth: 420)
                   .frame(maxWidth: .infinity, maxHeight: .infinity)
           } else if model.isStartingJob {
               VStack(spacing: 8) {
                   ProgressView().controlSize(.small)
                   Text("Starting…").font(.callout)
               }
               .frame(maxWidth: .infinity, maxHeight: .infinity)
           } else {
               Text("Select an image in the gallery, or generate one.")
                   .frame(maxWidth: .infinity, maxHeight: .infinity)
           }
       }
       .padding(16)
       .frame(maxWidth: .infinity, maxHeight: .infinity)
   }
   ```

   If S06 is merged, keep its `CanvasImageBar(model: model, image: image).padding(.top, 12)` directly after `SelectedImageView`, outside the `.overlay`.
9. `SelectedImageView`'s accessibility label stays "Selected image: \(image.prompt)". The smoke suite waits for it with the new image's token, and the canvas now shows the new image as soon as it is saved, so that still holds.
10. Tests: add to `Tests/MCAppTests/AppModelTests.swift`, reusing its stub patterns (`PNGFixture.sseHead`/`sseTail`, `EngineStubProtocol.finishHeld`, `eventually`, `imageCount`):
    - `theCanvasKeepsThePreviousImageWhileTheNextJobRuns`: generate once and wait for `selectedImage`; remember its id. Generate again with a held reply and wait for `runningProgress` of the second job. Expect `model.canvasImage?.id == firstID`.
    - `everyImageOfABatchTakesTheCanvas`: `batchCount = 2`, generate, wait until `imageCount(model) == 2`. Expect `model.selection == model.galleryImages.first?.id` (the newest).
    - `aGalleryClickStopsFollowing`: generate with `batchCount = 2` and a held second image. After the first image, call `model.selectGalleryImage(otherID, click: .plain)` on an older image, finish the hold, and expect `model.selection == otherID`.
    - Run the existing `AppModelTests`, `CollectionsTests` and `LoRAStackTests` unchanged; they read `model.selection` right after `generate()`, which is still the job id.
11. Format the touched files.

## Do not touch

- The gallery multi-selection (`gallerySelection`) and the D37 actions.
- `GalleryCollection` and `ImageCell`.
- The executor and queue order.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including the three new tests (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter AppModelTests`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0 (`python3 scripts/gui-smoke/run_smoke.py --models "$HOME/Library/Application Support/mlx-create/Models/Weights" --model-id Runpod/FLUX.2-klein-4B-mflux-4bit`).

With the capture kit, one model, one image already generated, window at 1100×692:

6. Set batch ×3 and press Generate. Poll `ax dump` every second: the text "Select an image in the gallery, or generate one." never appears, and an `AXImage` whose desc starts with "Selected image:" is present at every poll.
7. After the batch finishes, the canvas image desc equals the newest gallery tile's desc ("Image: …" minus the prefix).
8. Captures `I02_running_small_light.png` (old image plus step bar) and `I02_running_large_dark.png` are attached to the PR.

## Resolution

Done on branch `fix/audit-results-recovery-plan`, commit `0e4d109`. The reuse functions moved out of `AppModel.swift` into `AppModel+Reuse.swift` first (commit `8a7ef15`), because that file was at the size budget. Differs from the edit steps in three places: `isStartingJob` is false while the queue is paused or held, so a job that is merely queued does not blank the canvas; every gallery click, including ⌘ and ⇧, ends following; and `canvasImage` (not `canvasFallbackImageID`) is what the view binds to, which S06 and I03 reuse. Exercised: `swift build`, `swift test`, lint, the Debug `xcodebuild`, GUI smoke (`TEST SUCCEEDED`), and acceptance 6 to 8 on a live engine (no "Select an image" at any 1 s poll; the canvas image desc equals the newest tile's). Captures: `screens/I02_running_small_light.png`, `screens/I02_running_large_dark.png`. Not exercised: a sub-second blank between jobs, which a 1 s poll cannot see.
