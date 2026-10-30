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
