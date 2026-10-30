# I03 · Out of memory: say what happened where the user is looking, and offer Try Again

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 4, catastrophe: the failure shows up only as a 96×96 grey cell with 10 pt text truncated after "Clo…". The header says "Queue empty", the canvas says "Select an image…", and Retry hides in a right-click menu |
| Frequency | Whenever memory is short. Common on 16 GB Macs (HLD §11) and whenever other apps hold memory |
| Heuristics | H9 Help users recognize, diagnose, and recover from errors; H1 Visibility of system status |
| User task | (e) recover from an out-of-memory error |
| Strategy metric | **Failed generation rate**; time to first kept image |
| HLD decisions | No D* change. AGENTS.md: "Errors users see must be actionable" |
| Size | M |
| Depends on | I02 (`canvasFollowedJobs`, `canvasImage`) |

## Evidence

- Screenshots: `screens/04c-queue-cancelled_small_light.png` and `screens/08c-oom-failed-jobs_large_light.png`. Two real out-of-memory failures appear as strip cells reading "Failed · Not enough free memory to run this model. Clo…", with the header "Queue empty", a blank canvas, and no Retry visible. `screens/08-enhancer-memory-refusal_small_light.png`: Enhance failed with "The image engine rejected the request.", which names the wrong engine, does not say memory, and offers no action. The memory itself was taken by other generation tasks on the audit Mac (the engine log quotes "needs ~5.8 GB free … only 3.8 GB is available" and "needs ~1001MB … ~510MB available"); the app's handling is the finding.
- Code:
  - `Sources/MCEngine/EngineError.swift`: `OutOfMemoryFailure.message` is "Not enough free memory to run this model. Close other apps or models and try again." There is no app control to "close models", and on the 503 path the executor has already unloaded every resident model (`Executor.unloadResidentModels()`, `OutOfMemoryFailure.refusalUnloadsResidentModels`).
  - `EngineError.fromChatResponse(status:body:)` maps the engine's 400 admission refusal (upstream `src/server.zig` `memoryRefusalMessage`: "Prompt (N tokens) requires ~X MB GPU memory but only ~Y MB is available…", and `prefillNoFitMessage`: "… does not fit in GPU memory …") to `.badRequest`, whose copy is "The image engine rejected the request."
  - `Sources/MCApp/QueueStripView.swift`, `JobCell.statusContent` `.failed` shows the message at `.caption2` with `lineLimit(3)`. Retry exists only in `.contextMenu` and as a VoiceOver action.
- Contrast (capture kit `contrast.py`): the "Failed" label in `.red` on the `.quaternary` cell measures **2.86:1** (light), below 4.5:1.
- HIG, Feedback: "Use alerts to deliver critical — and ideally actionable — information … integrate status feedback into your interface near the items it describes."

## Current behavior

See Evidence. The user has to notice a small cell, read truncated 10 pt text, know that right-click reveals Retry, and act on advice ("close … models") the app gives no way to follow.

## Target behavior

- **Canvas failure card.** When the canvas selection is a failed job, the canvas shows (over the kept image, at the bottom, or centered when there is none) a card:
  - `Image(systemName: "exclamationmark.triangle.fill")`, `.red`, `.title2`.
  - Title "This image couldn't be made", `.headline`, `.primary`.
  - The job's `failure.message`, `.body`, `.primary`, full text (no line limit), `.textSelection(.enabled)`.
  - Buttons: **Try Again** (`.borderedProminent`; shown when `job.canRetry`) and **Dismiss** (`.bordered`; returns the canvas to the kept image).
  - Card: `.regularMaterial`, corner radius 10, padding 16, maximum width 460.
- **Follow-up failures.** When a job Generate started this session (`canvasFollowedJobs`) fails, even after saving some images, the canvas switches to its failure card.
- **Try Again** calls `retry(_:)`, and the retried job is followed again (I02), so its images take the canvas.
- **Copy.**
  - `OutOfMemoryFailure.message` = "There isn't enough free memory for this model right now. mlx-create has already freed its own memory. Quit apps you aren't using, then press Try Again."
  - `.enhancerOutOfMemory` = "There isn't enough free memory to run the prompt enhancer right now. Quit apps you aren't using, then try again."
  - `.badRequest` (chat routes only) = "The prompt enhancer rejected the request." Image routes keep "The image engine rejected the request."
- **Mapping.** A chat response with status 400 whose message contains "GPU memory" maps to `.enhancerOutOfMemory(engineMessage:)`.

## Edit steps

1. `Sources/MCEngine/EngineError.swift`:
   - Change `OutOfMemoryFailure.message` to the text above.
   - In `userMessage`, change the `.enhancerOutOfMemory` text to the text above.
   - In `fromChatResponse(status:body:)`, before `return enhancerSpecific(…) ?? fromResponse(…)`, add:

     ```swift
     // The engine's admission guard refuses a chat that does not fit with HTTP 400 and a message about GPU memory
     // (upstream src/server.zig memoryRefusalMessage / prefillNoFitMessage). That is a memory refusal, not a bad request.
     if status == 400, let message = parsed.message, message.contains("GPU memory") {
         return .enhancerOutOfMemory(engineMessage: message)
     }
     ```

   - Leave `fromResponse` (image routes) unchanged.
2. `Tests/MCEngineTests/EngineErrorMappingTests.swift`: add

   ```swift
   @Test("a 400 admission refusal on a chat route maps to enhancerOutOfMemory")
   func chatAdmissionRefusal() {
       let body = Data(#"{"error":{"message":"Prompt (596 tokens) requires ~1001MB GPU memory but only ~510MB is available and the hot prefix cache holds ~0MB more, all of which can be reclaimed (~0MB — the shortfall is elsewhere), which is not enough. Reduce prompt size, lower --ctx-size, or use a smaller model.","type":"invalid_request_error"}}"#.utf8)
       guard case .enhancerOutOfMemory = EngineError.fromChatResponse(status: 400, body: body) else {
           Issue.record("expected enhancerOutOfMemory")
           return
       }
   }
   ```

   and a second test asserting that `fromResponse(status: 400, body: thatBody)` is still `.badRequest` (image routes unchanged).
3. `Sources/MCApp/AppModel+Selection.swift` (from I02): add

   ```swift
   /// The failed job the canvas is showing, if the selection is one (I03).
   var selectedFailedJob: JobItem? {
       queueJobs.first { $0.id == selection && $0.status == .failed }
   }
   ```

4. `Sources/MCApp/AppModel+Projection.swift`, `reloadQueue()`: right after `queueJobs = items`, add:

   ```swift
   // A followed job that failed takes the canvas, so the failure shows where the user is looking (I03).
   if let failed = items.first(where: { $0.status == .failed && canvasFollowedJobs.contains($0.id) }) {
       canvasFollowedJobs.remove(failed.id)
       selection = failed.id
   }
   ```

5. `Sources/MCApp/AppModel+Queue.swift`, `retry(_:)`: after `try await queue.retry(jobID)` succeeds (inside the `do`), add `canvasFollowedJobs.insert(jobID)`.
6. `Sources/MCApp/CanvasView.swift`: add

   ```swift
   /// A failed job's reason and recovery, on the canvas (I03). Internal, not private, so a test can render it.
   struct FailureCard: View {
       let model: AppModel
       let job: JobItem

       var body: some View {
           VStack(alignment: .leading, spacing: 10) {
               HStack(alignment: .firstTextBaseline, spacing: 8) {
                   Image(systemName: "exclamationmark.triangle.fill")
                       .font(.title2)
                       .foregroundStyle(.red)
                       .accessibilityHidden(true)
                   Text("This image couldn't be made")
                       .font(.headline)
               }
               Text(job.failure?.message ?? "The image could not be generated.")
                   .font(.body)
                   .fixedSize(horizontal: false, vertical: true)
                   .textSelection(.enabled)
               HStack(spacing: 8) {
                   Spacer(minLength: 0)
                   Button("Dismiss") {
                       model.selection = model.canvasFallbackImageID
                   }
                   .buttonStyle(.bordered)
                   if job.canRetry {
                       Button("Try Again") {
                           Task { await model.retry(job.id) }
                       }
                       .buttonStyle(.borderedProminent)
                   }
               }
           }
           .padding(16)
           .frame(maxWidth: 460, alignment: .leading)
           .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
           .accessibilityElement(children: .contain)
           .accessibilityLabel("This image couldn't be made")
       }
   }
   ```

   In `ContentCanvas.body`, wrap the outer `VStack` with `.overlay(alignment: model.canvasImage == nil ? .center : .bottom) { if let job = model.selectedFailedJob { FailureCard(model: model, job: job).padding(16) } }`. When `selectedFailedJob` is non-nil and `canvasImage` is nil, do not show the "Select an image…" text: add `&& model.selectedFailedJob == nil` to the branch that shows it.
7. Tests in `Tests/MCAppTests/`, in a new `FailureCardTests.swift`:
   - `anOutOfMemoryFailureTakesTheCanvasAndCanBeRetried`: use `AppHarness.make(script:)` with a script that answers generation 1 with `.init(status: 503, body: Data(#"{"error":{"type":"out_of_memory","message":"insufficient memory"}}"#.utf8), tail: nil)` and later generations with a normal image (copy `AppModelTests`' 200 reply). Generate, wait until `model.selectedFailedJob != nil`, and expect `canRetry`. Call `await model.retry(id)`, then wait until `model.selectedImage != nil`.
   - `OutOfMemoryAgreementTests` and `OutOfMemoryCopyTests` compare against the constant, so they need no edit. Run them.
8. Format the touched files.

## Do not touch

- `Executor` OOM handling (unload, then fail), and retryability (`OutOfMemoryFailure.retryable`).
- The engine status banner (I06).
- The queue strip layout (I05 restyles it; this spec only adds the canvas card).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including the new tests (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0.
6. `rg -n "Close other apps or models" Sources` prints nothing.

Screenshot check. A real OOM cannot be forced on demand, so the card is rendered by a test:

7. In `FailureCardTests`, add `renderTheCardForReview`. Build the failed `JobItem` from the first test, then render it once per appearance:

   ```swift
   for scheme in [ColorScheme.light, .dark] {
       let renderer = ImageRenderer(
           content: FailureCard(model: model, job: job)
               .frame(width: 460)
               .background(scheme == .dark ? Color.black : Color.white)
               .environment(\.colorScheme, scheme))
       renderer.scale = 2
       let image = try #require(renderer.nsImage)
       let rep = try #require(NSBitmapImageRep(data: try #require(image.tiffRepresentation)))
       let png = try #require(rep.representation(using: .png, properties: [:]))
       try png.write(to: URL(fileURLWithPath: "/tmp/I03_card_\(scheme == .dark ? "dark" : "light").png"))
   }
   ```

   Add `import AppKit` and `import SwiftUI` to the test file.
8. Open `/tmp/I03_card_light.png` and `/tmp/I03_card_dark.png` and attach them to the PR. The whole message is visible (no ellipsis). `contrast.py` on a box around the message text gives ≥ 4.5:1 in both.
