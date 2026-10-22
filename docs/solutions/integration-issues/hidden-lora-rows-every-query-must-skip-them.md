---
title: "A hidden always-on LoRA row leaks through every query that forgets to skip it, including the import dedupe"
date: 2026-10-22
category: integration-issues
module: MCLibrary/LoRALibrary
problem_type: logic_error
component: library_store
severity: medium
applies_when:
  - "Adding a query, import path or error message that touches the `lora` table or LoRA failure copy"
  - "Changing how always-on LoRAs (HLD D44) are stored, counted or applied"
symptoms:
  - "Importing or picking the file an always-on row names showed 'Already installed: <hidden name>' or attached nothing"
  - "A user LoRA named like a hidden one was renamed with a ' 2' suffix"
  - "The over-limit job failure said 'at most 7', which reveals one hidden LoRA"
root_cause: missing_filter
resolution_type: code_fix
tags: [always-on, d44, hidden-row, dedupe, privacy, failure-copy]
---

# A hidden always-on LoRA row leaks through every query that forgets to skip it

## Problem
D44 stores an always-on LoRA as a real `lora` row flagged by a non-null `always_on_scale`, so the executor can find its file and the sweep keeps it. "Invisible" then depends on every reader remembering the flag. Five independent reviewers found the same gap: `commitLoRA` looked a file up by `sha256` across all rows, so a user import or shelf pick of the same bytes returned the hidden row. The import summary printed its name, a shelf attach silently did nothing, and `attachSourceIfMissing` wrote provenance onto it. The name-clash set (`SELECT name FROM lora`) also leaked the hidden name through a ` 2` suffix.

## Guidance
- Treat the list of "readers that must skip hidden rows" as part of the feature. When a row is hidden by a flag, grep every `FROM lora`, `LoRARecord.filter` and `Column("sha256")` site, not just the ones that feed a list.
- Writers and dedupe paths matter as much as listings. `lora.sha256` is UNIQUE, so a user import of an always-on file cannot become its own row. The commit stops with copy that says nothing about why (`this file cannot be added to the library`) rather than returning the hidden record.
- Counts and limits leak too. The executor no longer subtracts the always-on count from the engine's cap in a failure message. Always-on LoRAs yield to the user's stack (`prefix(8 - stack)`), and a stack over 8 fails with the plain limit. A status line in the log must not say the feature exists either.
- Test with a seeded hidden row against each public read and against the import of its own bytes (`LoRAAlwaysOnTests`). Check PNG invisibility with a positive control, and look for the 10-character A1111 hash form, not the 64-character hash that never appears.

## Why this matters
The same predicate (`always_on_scale IS NULL`) is written out by hand in many places. The review also noted that a named request on `LoRARecord` (visible versus always-on) would make drift harder. That refactor was not done here; it is recorded as a residual on the PR.

## References
- HLD D44 and `docs/lld/loras.md` "Curated shelf and always-on LoRAs".
- `Sources/MCLibrary/LoRALibrary.swift` (`commitLoRA`), `Sources/MCGeneration/Executor.swift` (`generateNext`, `loraFile(for:)`).
