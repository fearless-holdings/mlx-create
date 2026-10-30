# S04 · The window title is the collection, with its menu on the title

| | |
|---|---|
| Tag | STRUCTURE |
| Severity (Nielsen 0–4) | 2, minor: the current collection is not marked in its own menu, and the window is titled with the app name |
| Frequency | Every collection switch; the title is always on screen |
| Heuristics | H1 Visibility of system status; H4 Consistency and standards |
| User task | (f) change collection |
| Strategy metric | Nothing to learn |
| HLD decisions | No D* change. D35 operations (create, rename, switch, delete, save defaults) stay the same. Only the label of "Save Current Settings as Collection Defaults" changes; the behavior does not |
| Size | S |
| Depends on | none (S05 adds "New Collection…" to the File menu; independent) |

## Evidence

- Screenshots: `screens/16-collection-menu_small_light.png` and `screens/16d-collection-menu-two_small_light.png`. With "Portraits" current, neither "Default" nor "Portraits" shows a checkmark. `screens/16b-new-collection-sheet-error_small_light.png`: Create is enabled with an empty name, and pressing it shows the error "Enter a name for the collection."
- `screens/03a-ready-empty-hint_small_light.png`: the toolbar shows a "Default ⌄" pill and, beside it, the static window title "mlx-create".
- Code: `Sources/MCApp/CollectionMenu.swift`, `CollectionMenu.body`. The checkmark is `Label(entry.collection.name, systemImage: "checkmark")`. macOS menus do not draw a `Label` image as a check state; the accessibility dump shows `id=checkmark` and no mark. The delete reason is a disabled `Text(blockedReason)` menu item. `CollectionNameSheet.body` never disables Create.
- `MainWindow.body` puts `CollectionMenu` in `ToolbarItem(placement: .navigation)` and sets no `navigationTitle`, so the window title is the app name.
- HIG, Toolbars: "Don't title windows with your app name. Your app's name doesn't provide useful information about your content hierarchy." And: "Next to the title, the toolbar can include a document menu that contains standard and app-specific commands that affect the document as a whole, such as Duplicate, Rename, Move, and Export."
- Comparison: Photos titles the window with the current item and shows its position ("1,918 of 2,147") under the title. Pages and Numbers open a document menu from the title.

## Current behavior

The pill "Default ⌄" opens a menu listing every collection (with an invisible check mark), then New Collection…, Rename…, Delete Collection, a disabled reason line, and Save Current Settings as Collection Defaults. The title area beside it reads "mlx-create".

## Target behavior

- The window title is the current collection's name (`.navigationTitle(model.currentCollection.name)`), with the image count as subtitle (`.navigationSubtitle("\(count) images")`, using "1 image" for one and no subtitle at zero).
- Clicking the title opens the collection menu (`.toolbarTitleMenu`). The menu lists collections as an inline `Picker`, so the current one carries the system check mark, followed by: New Collection…, Rename…, Delete Collection (disabled when the store would refuse it), a divider, and **Remember These Settings for This Collection** (same action as before).
- The disabled reason line is removed. Delete stays disabled with `.help(reason)`.
- In the New/Rename sheet, Create/Rename is disabled while the trimmed name is empty.

## Edit steps

1. In `Sources/MCApp/CollectionMenu.swift`, split the menu content out of `CollectionMenu` into a new view:

   ```swift
   /// The collection menu's items (D35), shown from the window title (`toolbarTitleMenu`).
   struct CollectionMenuItems: View {
       @Bindable var model: AppModel

       var body: some View {
           let current = model.currentCollection
           let blockedReason = model.currentCollectionSummary?.deleteBlockedReason
           Picker(
               "Collection",
               selection: Binding(
                   get: { model.currentCollection.id },
                   set: { id in Task { await model.switchCollection(to: id) } })
           ) {
               ForEach(model.collections) { entry in
                   Text(entry.collection.name).tag(entry.id)
               }
           }
           .pickerStyle(.inline)
           .labelsHidden()
           Divider()
           Button("New Collection…") { model.collectionEditor = .create }
           Button("Rename…") { model.collectionEditor = .rename(id: current.id, currentName: current.name) }
           Button("Delete Collection") { Task { await model.deleteCollection(id: current.id) } }
               .disabled(blockedReason != nil)
               .help(blockedReason ?? "Delete this empty collection")
           Divider()
           Button("Remember These Settings for This Collection") {
               Task { await model.saveCurrentSettingsAsCollectionDefaults() }
           }
       }
   }
   ```

   Delete Collection keeps its current behavior: `AppModel.deleteCollection(id:)` shows no confirmation (the store refuses any collection that is not empty, D35), so its title has no ellipsis.
2. Keep `struct CollectionMenu` in the file and make its `Menu { … }` content `CollectionMenuItems(model: model)`. This is the fallback for step 4.
3. In `Sources/MCApp/MainWindow.swift`:
   - Delete the `ToolbarItem(placement: .navigation) { CollectionMenu(model: model) }` entry from `.toolbar { … }`.
   - After `.frame(minWidth: 1100, minHeight: 640)`, add:

     ```swift
     .navigationTitle(model.currentCollection.name)
     .navigationSubtitle(imageCountSubtitle)
     .toolbarTitleMenu { CollectionMenuItems(model: model) }
     ```

   - Add to `MainWindow`:

     ```swift
     private var imageCountSubtitle: String {
         let count = model.currentCollectionSummary?.imageCount ?? 0
         switch count {
         case 0: return ""
         case 1: return "1 image"
         default: return "\(count) images"
         }
     }
     ```

     Check the field name: `CollectionSummary` exposes `imageCount` (used by `CollectionsTests`: `model.collections.first { … }?.imageCount`).
4. Build and run (capture kit). If clicking the title opens no menu on this macOS version, revert step 3's `.toolbarTitleMenu` line, put `ToolbarItem(placement: .navigation) { CollectionMenu(model: model) }` back, and add `.toolbar(removing: .title)` after `.navigationSubtitle(…)`. The window still carries the collection name (Window menu, Mission Control), and the pill shows it on screen. Record which path you took in the PR description.
5. In `CollectionNameSheet.body`, add `.disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)` to the Create/Rename button, in place of `.disabled(isSaving)`.
6. Format the touched files.

## Do not touch

- `AppModel+Collections.swift` behavior (switch, create, rename, delete rules, D35).
- The "Move to Collection" submenu in `GalleryView.ImageCell`.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0 (`python3 scripts/gui-smoke/run_smoke.py --models "$HOME/Library/Application Support/mlx-create/Models/Weights" --model-id Runpod/FLUX.2-klein-4B-mflux-4bit`).

With the capture kit, one model installed and two collections ("Default" and "Portraits", created through the menu):

6. `ax dump`: the window's `title` is the current collection's name, and no `AXStaticText` in `AXToolbar` has the value `mlx-create`.
7. Open the collection menu (click the title, or the pill in the fallback). Capture the open menu with `screencapture -x -R <x>,<y>,600,400 S04_menu_light.png`, using the window's origin from `winid` for `<x>,<y>`. The row of the current collection shows the system check mark (✓) and no other collection row does. Attach the image to the PR.
8. In the New Collection sheet with an empty name, the Create button is `[disabled]` in `ax dump`.
