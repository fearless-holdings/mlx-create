# S05 · Put the app's commands in the menu bar, and make the window single

| | |
|---|---|
| Tag | STRUCTURE |
| Severity (Nielsen 0–4) | 3, major: ⌘R, ⌘E and ⌘. exist but nothing anywhere tells the user about them, and VoiceOver and Full Keyboard Access users cannot reach them through a menu |
| Frequency | Every session |
| Heuristics | H6 Recognition rather than recall; H7 Flexibility and efficiency of use; H4 Consistency and standards |
| User task | (b) tweak and generate again, (c) reuse an old image, (e) cancel a stuck job |
| Strategy metric | Nothing to learn (commands are discoverable where every Mac user looks first) |
| HLD decisions | No D* change. HLD §10 "Keyboard first" lists ⌘↩, ⌘E, ⌘., ⌘R; this spec makes them visible. The single window matches D28 (one app instance) and D33 (one three-panel window) |
| Size | M |
| Depends on | none |

## Evidence

- Menu bar observed with `ax dump` (`screens/ax/ax-empty.txt`): Apple, mlx-create, File (New Window, Close, Close All), Edit, View, Window, Help. There is no command for Generate, Enhance, Cancel, Reuse, Pause/Resume, Export, Models or LoRAs.
- Code: `Sources/MCApp/MainWindow.swift`, `private struct ShortcutButtons`: three buttons with `.opacity(0)`, `.frame(width: 0, height: 0)` and `.accessibilityHidden(true)`, carrying ⌘., ⌘R and ⌘E. ⌘↩ is on the Generate button in `GenerationPanel.bottomRow`.
- `App/MLXCreateApp.swift` uses `WindowGroup`, so File ▸ New Window opens a **second** main window on the same `AppModel`. Observed during the audit: after the window was closed, the app kept running with no window, and New Window opened a second `MainWindow` (tabbed with the first).
- HIG, The menu bar: "Even when commands are available elsewhere in your app, it's important to list them in the menu bar. Putting commands in the menu bar makes them easier for people to find, lets you assign keyboard shortcuts to them, and makes them more accessible to people using Full Keyboard Access. Excluding commands from the menu bar — even infrequently used or advanced commands — risks making them difficult for everyone to find."
- Comparison: Photos lists every image action (Export, Show in Finder, Delete) in its menus. Draw Things hides most actions behind toolbar icons, which is part of why it feels un-Mac-like to the user.

## Current behavior

The four app shortcuts work only for people who already know them. The menu bar holds only SwiftUI's default items, including "New Window", which breaks the one-window model.

## Target behavior

- Scene: `Window("mlx-create", id: "main")`, not `WindowGroup`. There is no "New Window" item. Closing the window quits the app (`applicationShouldTerminateAfterLastWindowClosed` returns `true`). The queue persists across relaunch (D29), so quitting loses no jobs.
- **File** menu: the "New" group is replaced by **New Collection…** (⇧⌘N).
- **Image** menu, a new `CommandMenu("Image")`, in this order:
  - Generate (⌘↩): disabled unless `canGenerate`.
  - Enhance Prompt (⌘E): disabled unless `canEnhance`.
  - Cancel Generation (⌘.): disabled unless a job is running or queued in the strip.
  - divider
  - Reuse All Settings (⌘R): disabled unless `canReuse`.
  - Export… (⇧⌘E): disabled when no image is selected or shown.
  - Show in Finder (no shortcut): same rule.
  - Move to Trash (**no shortcut**: ⌘⌫ would fire while typing in the prompt, and D37 delete has no undo): same rule.
  - divider
  - Pause Queue / Resume Queue (one item whose title follows `queueHeader`; disabled when the header is neither `.running` nor `.paused`).
  - divider
  - Models…
  - LoRA Library…
- `ShortcutButtons` is deleted. The Generate button loses its own `.keyboardShortcut` (the menu owns ⌘↩) and gets `.help("Generate (⌘↩)")`.

## Edit steps

1. Create `Sources/MCApp/MainCommands.swift`:

   ```swift
   import SwiftUI

   extension FocusedValues {
       /// The app model of the key main window, so menu commands act on it (docs/design-audit/specs/S05).
       @Entry var appModel: AppModel?
   }

   public struct MainCommands: Commands {
       @FocusedValue(\.appModel) private var model

       public init() {}

       public var body: some Commands {
           CommandGroup(replacing: .newItem) {
               Button("New Collection…") { model?.collectionEditor = .create }
                   .keyboardShortcut("n", modifiers: [.command, .shift])
                   .disabled(model == nil)
           }
           CommandMenu("Image") {
               Button("Generate") { run { await $0.generate() } }
                   .keyboardShortcut(.return, modifiers: .command)
                   .disabled(!(model?.canGenerate ?? false))
               Button("Enhance Prompt") { run { await $0.pressEnhance() } }
                   .keyboardShortcut("e", modifiers: .command)
                   .disabled(!(model?.canEnhance ?? false))
               Button("Cancel Generation") { run { await $0.cancelRunningOrSelected() } }
                   .keyboardShortcut(".", modifiers: .command)
                   .disabled(!hasCancellableJob)
               Divider()
               Button("Reuse All Settings") { run { await $0.reuseSelectedImageSettings() } }
                   .keyboardShortcut("r", modifiers: .command)
                   .disabled(!(model?.canReuse ?? false))
               Button("Export…") { runOnImages { await $0.exportSelected() } }
                   .keyboardShortcut("e", modifiers: [.command, .shift])
                   .disabled(!hasImageTarget)
               Button("Show in Finder") { runOnImages { await $0.revealSelected() } }
                   .disabled(!hasImageTarget)
               Button("Move to Trash") { runOnImages { await $0.deleteSelected() } }
                   .disabled(!hasImageTarget)
               Divider()
               Button(model?.queueHeader == .paused ? "Resume Queue" : "Pause Queue") {
                   run { model in
                       if model.queueHeader == .paused { await model.resumeQueue() } else { await model.pauseQueue() }
                   }
               }
               .disabled(!(model?.queueHeader.offersPause ?? false) && !(model?.queueHeader.offersResume ?? false))
               Divider()
               Button("Models…") { model?.openBrowser() }
                   .disabled(model == nil)
               Button("LoRA Library…") { model?.isLoRALibraryPresented = true }
                   .disabled(model == nil)
           }
       }

       private var hasCancellableJob: Bool {
           model?.queueJobs.contains { $0.status == .running || $0.status == .queued } ?? false
       }

       /// An image to act on: the gallery selection, or else the image on the canvas.
       private var hasImageTarget: Bool {
           guard let model else { return false }
           return !model.gallerySelection.isEmpty || model.selectedImage != nil
       }

       private func run(_ action: @escaping @MainActor (AppModel) async -> Void) {
           guard let model else { return }
           Task { await action(model) }
       }

       /// With nothing selected in the gallery, the canvas image becomes the selection first, so the action has a target.
       private func runOnImages(_ action: @escaping @MainActor (AppModel) async -> Void) {
           guard let model else { return }
           if model.gallerySelection.isEmpty, let image = model.selectedImage {
               model.selectGalleryImage(image.id, click: .plain)
           }
           Task { await action(model) }
       }
   }
   ```

   `gallerySelection`, `selectGalleryImage(_:click:)`, `canEnhance`, `pressEnhance()` and `isLoRALibraryPresented` are `internal`. They are visible because `MainCommands` lives in the `MCApp` module. `GalleryClick` lives in `GallerySelection.swift`. `JobStatus` lives in `MCLibrary`, so add `import MCLibrary` if the compiler asks for it.
2. In `Sources/MCApp/MainWindow.swift`:
   - Delete `.background(ShortcutButtons(model: model))` and the whole `private struct ShortcutButtons`.
   - Add `.focusedSceneValue(\.appModel, model)` after `.frame(minWidth: 1100, minHeight: 640)`.
3. In `Sources/MCApp/GenerationPanel.swift`, in `bottomRow`, on `Button("Generate")`: delete `.keyboardShortcut(.return, modifiers: .command)` and add `.help("Generate (⌘↩)")`.
4. In `App/MLXCreateApp.swift`:
   - Replace `WindowGroup {` with `Window("mlx-create", id: "main") {`. Leave the switch over `launch.phase` inside it unchanged.
   - After the closing brace of the `Window { … }` content, add `.commands { MainCommands() }`.
   - In `AppDelegate`, add:

     ```swift
     /// One window (D28, D33): closing it quits, and the queue resumes on the next launch (D29).
     func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
         true
     }
     ```

5. In `UITests/MLXCreateUITests/RestoreFlow.swift`, in the "Reuse all settings" step, replace the comment `// ⌘R is bound to a hidden zero-size view (MainWindow.swift); the tile menu item is the fallback.` with `// ⌘R is the Image ▸ Reuse All Settings menu command; the tile menu item is the fallback.` Change nothing else in that file.
6. Format every touched file.

## Do not touch

- The gallery tile context menu titles "Reuse prompt" and "Reuse all settings": `RestoreFlow` queries them by exact title. The menu bar item is "Reuse All Settings" (title case, HIG), so the two queries cannot collide.
- `GalleryCollectionView.keyDown` (Delete key in the gallery stays as it is).
- The queue cells' ⌥↑/⌥↓.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0 (`python3 scripts/gui-smoke/run_smoke.py --models "$HOME/Library/Application Support/mlx-create/Models/Weights" --model-id Runpod/FLUX.2-klein-4B-mflux-4bit`). The xcresult activity for the last step reads "Restored through the ⌘R shortcut".
6. `rg -n "ShortcutButtons|opacity\(0\)" Sources/MCApp` prints nothing.

With the capture kit and one model installed:

7. `ax dump <pid>` lists `AXMenuBarItem title="Image"` with `AXMenuItem` children titled, in order: Generate, Enhance Prompt, Cancel Generation, Reuse All Settings, Export…, Show in Finder, Move to Trash, Pause Queue (or Resume Queue), Models…, LoRA Library…. Dividers show as untitled items between them.
8. The File menu has a "New Collection…" item and no "New Window" item.
9. Type a prompt (`ax setvalue <pid> AXTextArea "Prompt" "a teapot"`), bring the app to the front, and send ⌘↩ (`osascript -e 'tell application "System Events" to key code 36 using command down'`). Within 10 s, `ax dump` shows an element whose desc starts with "Generation progress" or a queue cell whose desc contains "a teapot".
10. Close the window (`ax press <pid> AXCloseButton` does not work through `press`; use `osascript -e 'tell application "System Events" to tell (first process whose unix id is <pid>) to click button 1 of window 1'`). Within 6 s, `pgrep -f "MLXCSmokeHome <home>"` prints nothing, and `pgrep -f "<home>/"` prints nothing (the engine stopped too).

## Resolution

Done on branch `window-structure/menu-commands`, commits `1450d2d` and `4d625bb` (PR [#34](https://github.com/fearless-holdings/mlx-create/pull/34), the bottom layer of a three-PR stack). Differs from the edit steps in one place: the Generate button keeps its `.help(model.generateBlockReason ?? "Generate (⌘↩)")` and `.accessibilityHint` from I12, so only `.keyboardShortcut(.return, …)` came off it, because the Image menu owns ⌘↩. Code review by a second model found that Export…, Show in Finder and Move to Trash read `selectedImage` instead of the image on the canvas, so they were disabled while a freshly generated job was still running, and running one with nothing selected ended the canvas following the queued jobs; `4d625bb` makes them act on `canvasImage` by id, as the canvas image bar does. Exercised on the real engine with FLUX.2 klein 4B 4-bit: `swift build`, `swift test`, `swift format lint --strict`, the Debug `xcodebuild`, GUI smoke (exit 0), and a throwaway-home run of acceptance check 10 with a job running: closing the window stopped the app and its engine child (checked by home path in argv). Not exercised: the fix in `4d625bb` in the running app (it was reviewed and built, not driven), Export…'s save panel, and Show in Finder and Move to Trash through the menu on a live image.
