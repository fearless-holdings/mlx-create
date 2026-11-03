# I05 · Queue strip: cells you can tell apart, an honest header, and a way to clear old cells

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 3, major: every cell is a grey 96×96 square with no prompt; failed and cancelled cells pile up forever; the header says "Queue empty" while cells are on screen |
| Frequency | Every batch or multi-job session; failed and cancelled cells persist across relaunches |
| Heuristics | H1 Visibility of system status; H6 Recognition rather than recall; H3 User control and freedom |
| User task | (b) tweak and generate again (several jobs), (e) recover from a failure |
| Strategy metric | Failed generation rate (users notice and retry); nothing to learn |
| HLD decisions | No D* change. HLD §8.2 ("The queue strip … shows one cell per job with live progress") and D13 stay. Dismissal is a view preference stored in `UserDefaults`, like the D29 pause flag. It changes no job row |
| Size | M |
| Depends on | I02 (`selectJob`). Pairs with I03 (a click on a failed cell shows its card) |

## Evidence

- Screenshots: `screens/04-queue-several-jobs_small_light.png` (four identical "Queued · 0 of 6 saved" squares); `screens/04c-queue-cancelled_small_light.png` and `screens/08c-oom-failed-jobs_large_light.png` (the header reads "Queue empty" above a failed and a cancelled cell; the failure text is truncated).
- Code: `Sources/MCApp/QueueStripView.swift`. `JobCell` is 96×96 and shows no prompt (the prompt exists only in the accessibility label). `QueueHeaderView` shows "Queue empty" whenever nothing runs. `Sources/MCApp/AppModel+Projection.swift`, `reloadQueue()`, lists every paused, failed and cancelled job of the collection, with no dismissal.
- Contrast: "0 of 6 saved" (`.caption2`, `.secondary` on `.quaternary`) measures 3.80:1, and "Failed" (`.red` on `.quaternary`) 2.86:1 (capture kit `contrast.py`, light). Both are below 4.5:1.
- HIG, Feedback: "display status information in a passive way so that people can view it when they need it."

## Target behavior

**Cell.** 176 pt wide, 64 pt tall, `RoundedRectangle(cornerRadius: 10)` filled with `.quaternary`, padding 8. Selected cells keep the 3 pt accent stroke. Content, `VStack(alignment: .leading, spacing: 3)`:

1. Status line, `.callout`, `.primary`: a symbol and text.
   - Running: `ProgressView().controlSize(.mini)` before the first step, otherwise "Step 2 of 4".
   - Queued: `clock`, "Waiting".
   - Paused: `pause.circle`, "Paused".
   - Failed: `exclamationmark.triangle.fill` in `.red`, then "Couldn't be made".
   - Cancelled: `xmark.circle`, "Cancelled".
   - Done: `checkmark.circle`, "Done".
   Only the symbol carries colour; the text stays `.primary`.
2. Prompt line: `job.promptSnippet`, `.caption`, `.secondary`, `lineLimit(1)`, `.truncationMode(.tail)`.
3. Progress line: a `.linear` `ProgressView(value:total:)` while running with steps, else `"\(savedCount) of \(batchCount) saved"` in `.caption`, `.secondary`. Omit it when `batchCount == 1` and nothing is running.

Failed and cancelled cells get a dismiss button over the top-trailing corner: `Image(systemName: "xmark.circle.fill")`, `.secondary`, `.borderless`, `.help("Remove from the queue")`, `.accessibilityLabel("Remove from the queue")`. It is always visible, not only on hover.

**Header** (`QueueHeaderView`), `.caption` → `.callout`:

- Running: "Running", plus " · N waiting" when N queued jobs follow.
- Pausing and Paused: as today.
- Idle with no cells: "Queue empty".
- Idle with cells: no "Queue empty"; show "N finished" when only failed or cancelled cells remain.
- A **Clear** link button appears when at least one failed or cancelled cell is shown. It dismisses all of them.

**Dismissal** hides a failed or cancelled job from the strip. It is stored in `UserDefaults` under `dismissedQueueJobIDs` (an array of UUID strings), pruned on every reload to jobs that still exist in those states. It never changes the job row.

## Edit steps

1. `Sources/MCApp/AppModel.swift`: add `static let dismissedJobsDefaultsKey = "dismissedQueueJobIDs"` and

   ```swift
   /// Failed and cancelled jobs the user removed from the strip (I05). A view preference: the job rows are unchanged.
   var dismissedJobIDs: Set<UUID> = [] {
       didSet { defaults.set(dismissedJobIDs.map(\.uuidString), forKey: Self.dismissedJobsDefaultsKey) }
   }
   ```

   In `init`, after `self.selectedModelID = …`, add `self.dismissedJobIDs = Set((defaults.stringArray(forKey: Self.dismissedJobsDefaultsKey) ?? []).compactMap(UUID.init(uuidString:)))`.
2. `Sources/MCApp/AppModel+Projection.swift`, `reloadQueue()`, inside the `do` block:
   - After the line `let cancelled = try await store.jobs(status: .cancelled).filter { $0.collectionID == collectionID }`, add the ids of every finished job in **all** collections. Pruning must not forget dismissals that belong to another collection.

     ```swift
     let allFailed = try await store.jobs(status: .failed)
     let allCancelled = try await store.jobs(status: .cancelled)
     let allFinishedIDs = Set((allFailed + allCancelled).map(\.id))
     ```

   - Replace `for job in paused + failed + cancelled {` with `for job in paused + (failed + cancelled).filter({ !dismissedJobIDs.contains($0.id) }) {`.
   - Right after `queueJobs = items`, add `if !dismissedJobIDs.isSubset(of: allFinishedIDs) { dismissedJobIDs.formIntersection(allFinishedIDs) }`.
3. `Sources/MCApp/AppModel+Queue.swift`: add

   ```swift
   /// Hides failed or cancelled jobs from the strip (I05).
   func dismissJobs(_ ids: [UUID]) async {
       dismissedJobIDs.formUnion(ids)
       if let selection, ids.contains(selection) { self.selection = canvasFallbackImageID }
       await reload()
   }

   /// The failed and cancelled cells on screen.
   var finishedJobIDs: [UUID] {
       queueJobs.filter { $0.status == .failed || $0.status == .cancelled }.map(\.id)
   }
   ```

4. `Sources/MCApp/QueueStripView.swift`:
   - `QueueHeaderView`: change `.font(.caption)` to `.font(.callout)`. In `.idle`, show `Text("Queue empty")` only when `model.queueJobs.isEmpty`, else `Text("\(model.queueJobs.count) finished")`. In `.running`, append `Text(" · \(waiting) waiting")`, where `waiting = model.queueJobs.filter { $0.status == .queued }.count`, when `waiting > 0`. After the Pause/Resume buttons, add `if !model.finishedJobIDs.isEmpty { Button("Clear") { Task { await model.dismissJobs(model.finishedJobIDs) } }.buttonStyle(.link) }`.
   - `JobCell`: replace the label `VStack` and its `.frame(width: 96, height: 96)` with the layout in Target behavior (`.frame(width: 176, height: 64, alignment: .topLeading)`, corner radius 10). Keep the `Button` (now calling `model.selectJob(job.id)`, from I02), the context menu, the accessibility label and actions, and `.onKeyPress`.
   - Add the dismiss overlay as a **sibling** of the `Button`, not inside its label (follow `ImageCell`'s `.overlay(alignment: .topTrailing)` pattern in `GalleryView.swift`), shown when `job.status == .failed || job.status == .cancelled`:

     ```swift
     Button {
         Task { await model.dismissJobs([job.id]) }
     } label: {
         Image(systemName: "xmark.circle.fill")
             .foregroundStyle(.secondary)
     }
     .buttonStyle(.borderless)
     .padding(4)
     .help("Remove from the queue")
     .accessibilityLabel("Remove from the queue")
     ```

   - Add the accessibility action `"Remove from the queue"` (same condition) next to the existing ones.
5. Test, `Tests/MCAppTests/QueueDismissTests.swift`: cancel a queued job (pattern: `QueuePauseTests.pausedHarnessWithTwoJobs`, then `model.cancel(id)`), call `await model.dismissJobs([id])`, and expect `model.queueJobs` not to contain it. Relaunch the harness with the same defaults (`first.relaunch(script:)`), `start()`, and expect it still absent. Expect `harness.store.jobs(status: .cancelled)` still to contain it, since the job row is unchanged.
6. Format the touched files.

## Do not touch

- Job states, `JobQueue`, the executor and the database.
- ⌥↑/⌥↓ reordering and the context menu items.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including `QueueDismissTests` (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0.

With the capture kit, one model, window at 1100×692: queue two jobs with different prompts and cancel the second with its context menu Cancel.

6. `ax dump`: the strip's cells show `AXStaticText` values containing each job's prompt start (e.g. "a teapot", "a paper boat"). No `AXStaticText` "Queue empty" is shown while a cell is on screen.
7. Press "Remove from the queue" on the cancelled cell: its cell disappears. After quitting and relaunching, it is still gone.
8. `contrast.py` on the status text of a failed or cancelled cell (light and dark): ≥ 4.5:1.
9. Captures `I05_strip_small_light.png` and `I05_strip_small_dark.png` are attached to the PR.

## Resolution

Done on branch `work/queue-cells-i05`. Edit steps describe the as-built change, with these differences. The dismissal set persists through its own observer, and `init` reads the stored ids last, after every other stored property is set, so the observer can write the defaults. `reloadQueue` reads the failed and the cancelled jobs once each for every collection and filters them for the strip, so the prune sees the other collections without extra reads, and it prunes after `queueJobs` is assigned; a retried job leaves the finished states and loses its dismissal, so a later failure shows again. `retry` also drops the dismissal itself, as soon as the retry is accepted, so a retry that fails again before any reload has seen it queued still shows its new failure; no test can hold that window open, so it is covered by reading the code only. The idle header decides what it says in `QueuePresentation.idleSummary`: Queue empty with no cells, N finished only when every cell is failed or cancelled, and N waiting while any cell has not finished (it first said "0 finished" above waiting cells). Clear sits after Pause and Resume. The cell keeps the existing context menu (Move Up, Move Down, Retry, Cancel) unchanged; removal is the corner button (a 24 pt target) and a "Remove from the queue" accessibility action offered only on a finished cell. The cell's accessibility element is applied to its button, before the Remove overlay, so the Remove button stays an element of its own for VoiceOver and the accessibility tree. `JobItem.isDismissible` is the one definition of a failed or cancelled cell. `AppModel.swift` grew by the stored set, its defaults key and the init line only; `dismissJobs` and `finishedJobIDs` live in `AppModel+Queue.swift`, and HLD §10 names the header states and the removable cells. The GUI smoke runner now restores a string-array preference (the dismissals) the app changed, which it could not before, and its self-test covers it.

Exercised: `swift build`; `swift test` on the branch stacked on I09, all suites green, including the new `QueueDismissTests` (seven tests: a dismissed cancelled cell leaves the strip while the job row stays cancelled, the dismissal survives a relaunch, a retried job and its second failure both show again, a dismissal survives switching collections in both directions, Clear removes only failed and cancelled cells, dismissing the failed job on the canvas returns to the kept image with the selection back on it, and the idle header counts waiting cells instead of reporting zero finished); `swift format lint --strict` on every tracked Swift file prints nothing; `node scripts/check-file-size.mjs` on the changed files exits 0; `run_smoke.py --self-test` passes.

Not run here: the `xcodebuild` build, the GUI smoke, the `ax dump` and `contrast.py` checks, and the two captures for the PR; the orchestrator runs the app and the live checks.
