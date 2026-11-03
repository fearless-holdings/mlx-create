---
title: "Window Structure: Menu-Bar Commands, Collection Title, Toolbar Model Chip, Composer Disclosure - Plan"
type: feat
date: 2026-11-03
execution: code
---

# Window Structure: Menu-Bar Commands, Collection Title, Toolbar Model Chip, Composer Disclosure - Plan

## Summary

Ship the window-structure block of the design audit next: S05, then S04 with S03, then S02, executed from their specs in `docs/design-audit/specs/`. The results-and-recovery block is done (#27, #28, #30, #31, #32; tracker fixed in #33), so window structure is the next block in the audit's execution order (`docs/design-audit/README.md` section 3, step 3).

The audit tracker at `main` (`d0ae5e4`) reads 16 of 28 done. Open: S02, S03, S04, S05, S07, V01, V02, V05, V06. Deferred: I06. Blocked on an HLD decision: S08 (D34), S09 (D33).

## Units

One stack of three PRs, bottom to top, built with `gh stack` (AGENTS.md "Stacked PRs for multi-PR work"; read `.agents/skills/gh-stack/SKILL.md` first). Create the stack before writing code, one concern per layer, and use the non-interactive forms only.

```
(main) <- window-structure/menu-commands <- window-structure/title-and-chip <- window-structure/composer-options
```

Each layer is one PR, carries its own `Audit: <ID>` trailers and GUI smoke evidence, and gets its own review by a model other than the one that wrote it. A fix to a lower layer is committed on that layer's branch, then `gh stack rebase --upstack`.

| Layer | Specs | Size | Files |
|---|---|---|---|
| 1 `window-structure/menu-commands` | **S05**: menu-bar commands, single window | M | new `Sources/MCApp/MainCommands.swift`; edit `Sources/MCApp/MainWindow.swift`, `Sources/MCApp/GenerationPanel.swift`, `App/MLXCreateApp.swift`, `UITests/MLXCreateUITests/RestoreFlow.swift` (one comment) |
| 2 `window-structure/title-and-chip` | **S04 and S03** together | S + S | `Sources/MCApp/MainWindow.swift` (title menu and trailing chip), `Sources/MCApp/CollectionMenu.swift` (inline picker, empty-name guard), `Sources/MCApp/ModelChip.swift`, `Sources/MCApp/Models/ModelBrowserModel.swift` (`row(forRepo:)`), `Sources/MCApp/GenerationPanel.swift` (chip removed) |
| 3 `window-structure/composer-options` | **S02**: composer behind "More options" | M | `Sources/MCApp/GenerationPanel.swift`, `Sources/MCApp/AppModel.swift`, new `Sources/MCApp/AppModel+MoreOptions.swift`, new `Sources/MCApp/ComposerSettings.swift`, `UITests/MLXCreateUITests/GenerateFlow.swift`, `UITests/MLXCreateUITests/RestoreFlow.swift`, new `Tests/MCAppTests/MoreOptionsTests.swift` |

- **S05 is the bottom layer.** No dependencies, and the most widely visible change. It adds an Image menu (Generate, Enhance Prompt, Cancel Generation, Reuse All Settings, Export, Show in Finder, Move to Trash, Pause or Resume Queue, Models, LoRA Library), replaces `WindowGroup` with a single `Window`, and deletes the hidden zero-size `ShortcutButtons`, which VoiceOver and Full Keyboard Access users cannot reach. Premises checked at `main`: `ShortcutButtons` is still in `MainWindow.swift`, `App/MLXCreateApp.swift` still uses `WindowGroup`, and `AppDelegate` has no last-window-closed hook.
  - **Deviation from S05 step 3.** I12 already shipped, so the Generate button already has `.help(model.generateBlockReason ?? "Generate (⌘↩)")` and `.accessibilityHint(model.generateBlockReason ?? "")` (`Sources/MCApp/GenerationPanel.swift`). Delete only `.keyboardShortcut(.return, modifiers: .command)` and keep both modifiers; adding a plain `.help("Generate (⌘↩)")` would replace the disabled reason first-run users see.
- **S04 and S03 share a layer.** S04 deletes the `ToolbarItem(placement: .navigation)` that S03's step 3 inserts after, and each spec's acceptance reads the other's toolbar item, so they are one change set. The README orders S04 before S03. S05's File menu "New Collection…" is independent of S04.
- **S02 is the top layer.** The README puts it after S03 so the left-panel at-rest control count lands at its target. S02's own list is at most 10 controls with the model chip still in the panel; S03 takes it to 9, and S07 takes it to the README's 8. Because S03 sits below S02 in the stack, S02's acceptance runs at 9, which passes the "at most 10" check. S02 does not build Fast/Balanced/Quality step presets, because no family record defines them (HLD section 8.3 stays open).
- **Tracker bookkeeping.** Each layer edits only its own Status rows and spec Resolution sections. The Progress count and date in `docs/design-audit/README.md` are recomputed from the landed README each time a layer rebases, as the previous round's plan did, so a stale count never merges.

## Verification

The specs carry acceptance checks. Each layer uses its spec's checks, plus what is added below.

- Every layer: `swift build`, `swift test`, `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` printing nothing, and an `xcodegen generate` plus `xcodebuild` Debug build.
- **Layer 1.**
  - Run the GUI smoke (`scripts/gui-smoke/run_smoke.py`); its "Reuse all settings" step now goes through the Image menu command. That is the only menu command the smoke fires, so the rest of the menu needs the state matrix below.
  - `ax dump` lists the Image menu items in spec order, and File has "New Collection…" and no "New Window".
  - **Menu state matrix**, read from `ax dump` and fired where noted:
    - Empty library: Generate, Enhance Prompt, Cancel Generation, Reuse All Settings, Export…, Show in Finder, Move to Trash and Pause Queue are all `[disabled]`; Models… and LoRA Library… are enabled.
    - One model and a typed prompt: Generate is enabled.
    - An image selected: Reuse All Settings, Export…, Show in Finder and Move to Trash are enabled; fire Export… once.
    - A running job: Cancel Generation is enabled and the queue item reads "Pause Queue". A paused queue reads "Resume Queue".
  - With an empty home, the Generate button's help text is "Download a model to start" (I12 survives).
  - Closing the window stops the app and its engine child, checked by matching the throwaway home path in argv, never the process name. Run it twice: idle, and while a job is running, then relaunch and confirm the job is back in the queue (D29). The first guards the child process; the second guards the path every user takes with an accidental ⌘W.
- **Layer 2.** Run the GUI smoke; it finds the chip by the "Model: " accessibility prefix, so that must survive the move. The prefix alone does not prove S03's point: also check the S03 `ax dump` step that expects exactly `Model: FLUX.2 klein 4B`, which needs the signed catalog to list the installed model. Attach light and dark captures. S04's empty-name guard is checked by its `ax dump` step (Create is `[disabled]` with an empty name).
- **Layer 3.** Run the GUI smoke, and attach captures showing Size and "More options" visible without scrolling at 1100 by 640. The S02 smoke edit must open "More options" before the first seed interaction: `showMoreOptions()` goes first in GenerateFlow's "Choose a fixed seed" step as well as "Fix the seed", because the seed policy buttons exist only once the disclosure is open, and it stays first in RestoreFlow's "Change prompt, seed, seed policy and size" step.
- **Permanent tests.** S02 adds `Tests/MCAppTests/MoreOptionsTests.swift` with its three tests (defaults carry no summary; a fixed seed or steps appear in the summary; Reuse opens the disclosure). They catch a non-default seed or step count hiding behind a collapsed disclosure, and miss layout. No permanent test for menu or toolbar wiring: the matrix above and the GUI smoke cover it once, at ship time, and do not guard against a later regression. That is the cost of the choice.

## Decisions

- Settled by S05, open to override: closing the window quits the app (D28, D29). Jobs persist across relaunch, so no queue is lost. The risk is the AGENTS.md gotcha that a hard kill can leave `mlx-serve` running, which is why Layer 1's checks cover the child and a mid-job close.
- Each shipped finding updates its Status row in the audit README section 2, gets a Resolution section in its spec, and carries `Audit: <ID>` in the layer's PR body and commit message.

## Out of scope

- **S07**, the LoRA sheet's one entry point: the LoRA block (README section 3, step 5), independent of this stack. It gets its own plain PR or stack, planned separately, and shipping it leaves S08 one decision away.
- S08 and S09: blocked on the D34 and D33 decisions. Both specs carry the decision-log text.
- I06: deferred until a live engine kill can be exercised.
- V01, V02, V05, V06: wait for STRUCTURE. V01's token file can be created at any time, but migrating the screens waits until S02, S03 and S06 stop rewriting them.
