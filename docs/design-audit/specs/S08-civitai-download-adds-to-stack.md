# S08 · Civitai: a finished download goes on the stack (needs an HLD change first)

| | |
|---|---|
| Tag | STRUCTURE |
| Severity (Nielsen 0–4) | 3, major: after a Civitai download the user has to switch tabs, find the row and press Add, and the footer has to explain this |
| Frequency | Every Civitai LoRA |
| Heuristics | H7 Flexibility and efficiency of use; H2 Match between system and the real world; H5 Error prevention |
| User task | (d) add a LoRA from Civitai |
| Strategy metric | Time to a kept image with the LoRA the user wanted; nothing to learn |
| HLD decisions | **Changes D34's amendment.** "A finished download goes to the library only and is not attached to the generation stack" (HLD §3, Amendment 2026-10-19). D43 already reversed this for shelf items. **Do not start the code until the HLD carries the new decision below and the user has approved it** |
| Size | M |
| Depends on | S07 (tab labels). HLD update first |

## Evidence

- Screenshot: `screens/11-lora-civitai_small_light.png`. Footer: "Downloads keep going if you close this sheet. A downloaded LoRA goes to your library, not the stack." Each row's button reads "Download".
- Code: `Sources/MCApp/Civitai/CivitaiBrowseModel.swift`, `commit(_:acceptedAt:result:slot:)`. It stores the file with `store.commitStagedLoRA` (which returns `LoRAImportOutcome.added(LoRARecord)` or `.duplicate(existing:)`), then calls `libraryChanged()`. Compare `ShelfModel`, which `AppModel.init` connects through `shelf.connect { id, scale in … self.addToLoRAStack(id: id, weight: scale) }`.
- Walkthrough (d), current Civitai path: 9 clicks, 2 tab switches, and one rule to learn ("downloads don't go on the stack").

## HLD change to make first

Add to the decision log in `docs/HLD.md` (next free ID; D51 at the time of the audit):

> **D51** | **A finished Civitai download goes on the generation stack** when it fits the selected model's family and the stack has room (the per-request cap, D44). Otherwise it goes to the library only, as before. The row's action reads "Download and Add". This reverses the D34 amendment's "a finished download goes to the library only" for Browse downloads, as D43 did for shelf items. | The user downloads a LoRA to use it now; making them find it again in another tab adds clicks and a rule to learn (design audit S08) |

Also edit the D34 amendment paragraph to say "superseded by D51 for the stack rule".

## Current behavior

Download → license sheet → "Accept and download" → the row shows "Added to your LoRAs" → the user switches to Installed, finds the row and presses Add → Done.

## Target behavior

- The row button reads **Download and Add**, and **Retry** after a failure.
- When a download is committed (`.added(record)` or `.duplicate(existing: record)`) and `record.family` equals the selected model's family ID, the LoRA is added to the stack at weight 1.0 through `AppModel.addToLoRAStack(id:weight:)`, which already enforces the cap.
- The row status then reads "Added to the stack" (`checkmark.circle`, green symbol, text in `.primary`). When it fits no selected family, or the stack is full, it reads "Added to your LoRAs".
- The footer reads: "Downloads keep going if you close this sheet."

## Edit steps (only after the HLD change is merged)

1. `Sources/MCApp/Civitai/CivitaiBrowseModel.swift`:
   - Add a stored callback beside `libraryChanged`: `private var loraCommitted: @MainActor (LoRARecord) async -> Bool = { _ in false }`. Its result means "it went on the stack".
   - Add a `loraCommitted` parameter to `connect(selection:libraryChanged:)`, defaulting to `{ _ in false }`, and store it.
   - In `commit(...)`, keep the `outcome` and, after `await refreshInstalled()` and `await libraryChanged()`, add:

     ```swift
     let record: LoRARecord? = switch outcome {
     case .added(let record): record
     case .duplicate(let existing): existing
     }
     if let record, await loraCommitted(record) {
         statuses[modelID] = .addedToStack
     }
     ```

     Hoist the outcome out of the `do` block: declare `var committed: LoRAImportOutcome?` before the `do`, set `committed = outcome` inside it, and replace `switch outcome` above with `if let committed { switch committed { … } }`, giving `record` the value `nil` when `committed` is nil. `LoRARecord` is in `MCLibrary` and has `id` and `family`.
   - Add `case addedToStack` to `CivitaiRowStatus` (find it with `rg -n "enum CivitaiRowStatus" Sources`), and handle it wherever the enum is switched over (`rg -n "case .added" Sources/MCApp`). It behaves like `.added` everywhere except the status text.
2. `Sources/MCApp/AppModel.swift`, in `init`, change the `civitai.connect(...)` call to pass:

   ```swift
   loraCommitted: { [weak self] record in
       guard let self, record.family == self.loraFamily?.id else { return false }
       // `libraryChanged` has already refreshed `loraRecords`, which `addToLoRAStack` requires.
       self.addToLoRAStack(id: record.id, weight: 1.0)
       return self.loraSlots.contains { $0.id == record.id }
   }
   ```

3. `Sources/MCApp/Civitai/CivitaiBrowseView.swift`:
   - In `CivitaiResultRowView.actionView`, change `Button(isFailed ? "Retry" : "Download")` to `Button(isFailed ? "Retry" : "Download and Add")`, and its accessibility label to match.
   - In `statusView`, add `case .addedToStack: Label("Added to the stack", systemImage: "checkmark.circle").font(.caption)`, with `.symbolRenderingMode(.multicolor)` on the image only, and the text in `.primary`.
   - In `footer`, replace the idle text with "Downloads keep going if you close this sheet."
4. Add a test to `Tests/MCAppTests/CivitaiDownloadModelTests.swift`, following that file's existing download test: after a download of a LoRA classified for the selected family completes, `model.loraStack` contains it; with a different family selected, it does not.
5. Format the touched files.

## Do not touch

- The license sheet and the acceptance record (D20).
- The Civitai key rules (Keychain only, sent only to civitai.com).
- Shelf behavior (D43) and always-on LoRAs (D44).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including the new test (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. `rg -n "goes to your library, not the stack" Sources` prints nothing, and `docs/HLD.md` contains the new decision row.

With the capture kit (light network use; Civitai rate limits apply), FLUX.2 klein 4B selected:

6. In the Civitai tab, every result row's button reads "Download and Add". Download one small LoRA (under 30 MB, e.g. a "Slider" LoRA). Afterwards the row reads "Added to the stack", and the left panel's LoRA section shows it as a stack row (`ax dump` shows an `AXCheckBox` whose desc starts with its name).

## Resolution

Approved by the author on 2026-11-05 as D51 (the D34 amendment is marked superseded for the stack rule, and D43's "Civitai downloads keep that rule" now says D51 reversed it). Done in [#40](https://github.com/fearless-holdings/mlx-create/pull/40). The row reads "Download and Add" / "Retry", then "Added to the stack" or "Added to your LoRAs"; the footer reads "Downloads keep going if you close this sheet." The code follows the spec's edit steps, with these differences:

- The commit outcome is switched exhaustively, so `.restored` (a file the user had deleted) counts as added like `.added`. A duplicate keeps no "just added" mark unless it goes on the stack.
- The `loraCommitted` closure body lives in `AppModel.attachDownloadedLoRA(_:)` (`AppModel+LoRA.swift`), not inline in `AppModel.init`: `AppModel.swift` was at its file-size budget.
- `CivitaiRowStatus.showsAddedMark` covers both `.added` and `.addedToStack`, so the Installed tab clears and reads both marks. The status label sets the green only on the symbol; the text keeps the default colour.
- When the stack is full, `pushLoRASlot` (the shared tail of `addToLoRAStack` and `attachDownloadedLoRA`) still shows the usual "A job can use up to N LoRAs" notice in the panel. The row then reads "Added to your LoRAs".
- `addToLoRAStack` now returns whether the LoRA is on the stack (`@discardableResult`). `attachDownloadedLoRA` decides fit with the existing `loraFit` rule and calls `pushLoRASlot` directly, so it needs neither a library scan nor a second look at `loraSlots`.
- A `.duplicate` outcome stored nothing, so it skips the two library re-reads (`refreshInstalled`, `libraryChanged`) that `.added` and `.restored` still run, and it can still go on the stack.

Exercised: `swift test`, strict format lint, the Debug `xcodebuild`, and the GUI smoke (passed, 1 test, 2026-11-05, on the simplified top of the stack; it does not touch the Civitai tab). The three `.added` assertions in `CivitaiDownloadModelTests` now expect `.addedToStack`; new tests check that a LoRA for another family than the selected model stays off the stack, that a download into a full stack stays in the library with the cap notice and the `.added` row, and that a duplicate download stores nothing new and still goes on the stack; `addedModelIDs` is asserted before and after `installedTabShown()`. Live download (check 6), in the real app in a scratch home with FLUX.2 klein 4B selected and no Civitai key, on the build before the simplify pass: the Civitai tab listed 20 rows, every action reading "Download and Add" and none "Download"; pressing it on "Klein Anatomy / Quality Fixer" opened the license sheet, and Accept and Download then wrote `Models/LoRAs/<family>/e035a00e66-klein-anatomy-quality-fixer.safetensors`, switched the row to a disabled button reading "Added to the stack", and put "Klein Anatomy / Quality Fixer, enabled, weight 1" in the panel's LoRA stack. Run again on the simplified build with "Slider-LoRA for Klein4B": license sheet, then "Added to the stack" and "Slider-LoRA for Klein4B, enabled, weight 1" in the stack. The duplicate path was not run live. Known and accepted: `attachDownloadedLoRA` checks the family only, so switching model size (Klein 4B to 9B) during a download can put a LoRA of the other size on the stack (D51 specifies family-only).
