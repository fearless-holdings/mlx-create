---
title: "Launching mlx-create with an empty library to test the first-run flow"
date: 2026-10-21
category: developer-experience
module: MCApp/AppModel
problem_type: developer_experience
component: development_workflow
severity: low
applies_when:
  - "Manually testing the no-models canvas, the recommended-model card, or any first-launch path"
  - "The developer's own library already holds installed models, so the empty state never shows"
symptoms:
  - "The recommended-model card (D42) and the 'No image models installed' canvas cannot be reached on a dev machine"
  - "open --env HOME=... still opens the real library"
root_cause: incomplete_setup
resolution_type: environment_setup
tags: [manual-test, first-run, empty-state, application-support, cffixed-user-home]
---

# Launching mlx-create with an empty library to test the first-run flow

## Context
The first-run canvas only appears when zero image models are installed (`EmptyModelsView`). A developer's real library is rarely empty, and the app has no override flag or environment variable for its data location. The app resolves it through `FileManager` as `.applicationSupportDirectory` plus `mlx-create` (`Sources/MCApp/AppModel.swift:245-247`), so everything (library DB, `Models/`, `Engine/`) lives under the user's real `~/Library/Application Support`.

## What Didn't Work
- **`HOME=...` on the launch.** Recorded from an earlier session (prompt-history PR): an app started with `HOME` overridden still used the real library. `applicationSupportDirectory` is not derived from the process `HOME`. (auto memory [claude])
- **Moving the real `Application Support/mlx-create` aside.** Works, but puts the real library at risk of being left renamed if the run is interrupted. Not needed.

## Guidance
Point `CFFIXED_USER_HOME` at a throwaway directory:

```bash
mkdir -p /tmp/mc-empty-home
open -n --env CFFIXED_USER_HOME=/tmp/mc-empty-home build/Build/Products/Debug/mlx-create.app
```

Verified 2026-10-21 on macOS 26: the app created `Library/Application Support/mlx-create/{Library,Models,Engine}` under `/tmp/mc-empty-home` and the real library was not touched. The user confirmed the "No image models installed" canvas with the recommended card appeared.

Clean up afterwards:

```bash
osascript -e 'tell application "mlx-create" to quit'
pgrep -fl "mlx-serve|mlx-create.app"   # the engine child can outlive the app
rm -rf /tmp/mc-empty-home
```

## Why This Matters
Without it the empty-state and onboarding work cannot be seen on a developer machine, so UI there ships unviewed. `CFFIXED_USER_HOME` is read by Foundation when it resolves the home directory, which is why it works where `HOME` does not. [INFERENCE] The mechanism is not documented by Apple; the observed behavior above is the evidence.

## When to Apply
Any manual test of first launch, a clean install, or migrations from an empty database. Installs started in this mode land in the throwaway home, so a 5 GB+ model download goes to `/tmp` and is deleted with it.
