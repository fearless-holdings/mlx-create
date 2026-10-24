---
title: "App tests with a reference-timed model start a real calibration unless the load is held"
date: 2026-10-24
category: developer-experience
module: MCApp/AppModel
problem_type: developer_experience
component: testing_framework
severity: medium
applies_when:
  - "An AppHarness test installs a catalog model that carries reference_timing and passes engineVersion"
  - "A test asserts that no baseline or no estimate exists"
symptoms:
  - "A 'no baseline means no estimate' test passes without reaching the code it names"
  - "A baseline row appears in a test that never asked for calibration"
root_cause: test_isolation
resolution_type: test_fix
tags: [calibration, app-harness, estimates, empty-engine, hold-loads]
---

# App tests with a reference-timed model start a real calibration unless the load is held

## Context
`AppModel.refreshModels()` ends by calling `executor.kickIfCalibrationDue()` (D48). With an `engineVersion`, an installed image model whose catalog entry has `reference_timing`, and no baseline for that version, the executor really runs the two-render calibration against the stubbed engine and stores a baseline. `AppHarness` passes both inputs through when a test sets them, so any such test is a calibration test whether it means to be or not.

## What Didn't Work
- Calling `refreshEstimates()` without `refreshModels()` in a "no baseline" test. The browser rows are empty then, so `estimates.isEmpty` holds for the wrong reason.
- Calling `refreshModels()` in that test without holding the load. Calibration finishes in the background and writes the baseline the test is asserting is absent.

## Guidance
- To assert "no baseline", pass `holdLoads: [model.repo]` to `AppHarness.make`, call `refreshModels()`, assert the rows hold the timed model (`#require`), then run the assertion, then `EngineStubProtocol.finishHeld(endpoint)`.
- To assert "baseline appears", use `eventually { store.baseline(engineVersion:) != nil }`, never a fixed sleep.
- Tests that need a baseline without running calibration save one with `store.saveBaseline` before `model.start()`.
- A model without `reference_timing`, or a harness without `engineVersion`, never calibrates, which is how the rest of the suite stays unaffected.

## Why This Matters
Timing and calibration tests pass vacuously when the rows never load, and fail intermittently when calibration races the assertion. Both look like estimator bugs.

## Applicability
`Tests/MCAppTests/EstimateDisplayTests.swift` and `CalibrationTriggerTests.swift` show the patterns. Design rationale for calibration itself lives in `docs/lld/calibration.md`.
