---
title: A toolbar button with Label content shows its title, not the Button's accessibility label
date: 2026-11-04
category: ui-bugs
module: MCApp/ModelChip
problem_type: ui_bug
component: frontend
symptoms:
  - "The GUI smoke fails at its first step with 'the Model chip never appeared: the app did not load the installed model', although the model is installed and loaded"
  - "ax dump shows the toolbar button's desc as the visible title (FLUX.2 klein 4B), with no element whose desc begins 'Model: '"
root_cause: wrong_api
resolution_type: code_fix
severity: medium
tags: [swiftui, toolbar, accessibility, xcuitest, gui-smoke, label, s03]
---

# A toolbar button with Label content shows its title, not the Button's accessibility label

## Problem

Moving `ModelChip` from the left panel into the window toolbar (audit S03) kept `.accessibilityLabel("Model: \(chipTitle)")` on the `Button`, which the GUI smoke relies on to find the chip (`element(labelPrefix: "Model: ")` in `UITests/MLXCreateUITests/GenerateFlow.swift`). In the toolbar the label no longer reached assistive technology, so the smoke stopped at launch and VoiceOver read the bare model name.

## Symptoms

- GUI smoke, step "Launch with the model installed": `the Model chip never appeared: the app did not load the installed model`. The message points at the engine, not at the label.
- `./ax dump` of the toolbar, before the fix:

  ```
  AXToolbar
    AXButton desc="FLUX.2 klein 4B" help="Choose the image model"
  ```

- Before the move, with the chip in the left panel, the smoke found it by this label and passed. The spec's own replacement code for the chip used `Label(chipTitle, systemImage: "cpu")`, which is where the `Label` came from.

## What Didn't Work

- Keeping the Button-level `.accessibilityLabel` and expecting it to win. In the toolbar it did not.
- Putting `.accessibilityElement(children: .ignore)` and the label on the `HStack` inside the button's content, still around a `Label`. The dumps after these attempts still showed no `Model: ` element.
- `.accessibilityRepresentation { Button("Model: …") }`. The edit that introduced it was malformed and was replaced before a build checked it, so this attempt is not evidence either way.
- Reading the chip through `ax press` or a click. Neither shows the accessible name; read it from `ax dump`.

## Solution

Replace the `Label(chipTitle, systemImage: "cpu")` with an `Image` and a `Text` inside the button's label `HStack`, and keep the label on the `Button`. The fit warning moved from a per-icon label into the button's value:

```swift
Button { isOpen.toggle() } label: {
    HStack(spacing: 6) {
        Image(systemName: "cpu")
        Text(chipTitle)
        if let fit = selectedFit, fit == .tight || fit == .exceeds {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
.accessibilityLabel("Model: \(chipTitle)")
.accessibilityValue(fitWarning ?? "")
```

After it, `ax dump` reads `AXButton desc="Model: FLUX.2 klein 4B"` inside `AXToolbar` and the smoke passes.

## Why This Works

[INFERENCE] SwiftUI's toolbar derives a button's accessible name from a `Label`'s title, and that name takes precedence over a label set on the enclosing `Button`. An `Image` plus `Text` carries no `Label` for it to adopt, so the modifier stands. What was observed is only the pair of dumps: `Label` content gave the visible title, `Image` plus `Text` gave `Model: …`, with the same modifier in both. The cause was not isolated further, and it was seen on one macOS and SwiftUI version only.

## Prevention

- Do not change the chip's content back to a `Label` while it sits in the toolbar: that looks like a harmless simplification and silently breaks both the smoke lookup and the spoken label.
- Check any toolbar control whose accessibility name matters with `./ax dump` on the toolbar (`docs/design-audit/capture-kit.md`), not only with `swift build`.
- The smoke's launch-step failure message blames the engine for a missing label. That is a proposal for whoever owns the smoke: name the label prefix in the message so the next failure points at the cause. Not applied.
- When a platform release may have changed this, restore the `Label`, run `./ax dump`, and see whether `Model: ` survives.

## Related

- `docs/design-audit/specs/S03-model-chip-in-toolbar.md`, Resolution section.
- `Sources/MCApp/ModelChip.swift`.
