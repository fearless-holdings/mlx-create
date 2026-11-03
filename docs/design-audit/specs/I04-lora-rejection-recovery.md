# I04 · LoRA rejected: plain copy without internal ids, and a one-click fix

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 3, major: the message shows the raw engine id ("The model ddalcu/Krea-2-Turbo-MLX-Serve-mixed-4-8 cannot use …"), and the fix takes 4 clicks in a scrolled panel |
| Frequency | Rare. The local header check (HLD §8.6) catches most mismatches, but the engine's 400 is the final authority (AGENTS.md) |
| Heuristics | H9 Help users recognize, diagnose, and recover from errors; H2 Match between system and the real world |
| User task | (e) recover from a LoRA mismatch |
| Strategy metric | Failed generation rate; nothing to learn |
| HLD decisions | No D* change. D44's retry-without-always-on rule and the "copy names only the user's LoRAs" rule stay |
| Size | S |
| Depends on | I03 (the canvas `FailureCard`) |

## Evidence

- Not reproduced live: the pre-check (`LoRAFit`) greys out a mismatched LoRA before generation, and no LoRA on the audit Mac passes the header check yet fails in the engine. The behavior below comes from the code and its tests.
- Code:
  - `Sources/MCGeneration/FailureMapping.swift`, `failure(for:request:)`: "The model \(request.modelID) cannot use \(named). Remove or replace the LoRA and try again." (`retryable: false`).
  - The same file's `.loraMissing`, `.loraChanged` and `.loraLimitExceeded` messages also embed `modelID`.
  - `Tests/MCGenerationTests/LoRAExecutorTests.swift` asserts `failure.message.contains(kreaModel)`, which pins the raw id into the copy.
  - The fix today: scroll the left panel to LoRAs, expand the row (chevron), click "Remove from stack", then Generate. The failed cell stays in the strip.
- AGENTS.md: "Map engine failures (OOM, LoRA mismatch, missing weights) to plain-language messages."

## Target behavior

- Copy (no model ids; the failure card already sits next to the model chip):
  - Engine rejection: `This model can't use \(named). Remove it from the LoRA stack, then generate again.` Here `named` is the quoted list of the job's LoRA names, as today.
  - `.loraMissing`: `LoRA "\(name)" is no longer in your LoRA library. Import it again, then press Try Again.`
  - `.loraChanged`: `LoRA "\(name)" changed after it was imported. Remove it from the stack or import it again, then generate again.`
  - `.loraLimitExceeded`: `This job carries \(count) LoRAs and a job can use at most \(limit). Remove some from the stack, then generate again.`
- The `FailureCard` (I03) shows **Remove LoRAs from Stack** (`.borderedProminent`) when the failure is not retryable and the failed job carried LoRAs. It removes those LoRA ids from the composer stack, sets `loraNotice` to `Removed \(names) from the stack. Press Generate to try again.`, and returns the canvas to the kept image.

## Edit steps

1. `Sources/MCGeneration/FailureMapping.swift`: replace the four messages with the texts above. `modelID` stays a parameter of the enum cases; it is simply no longer interpolated.
2. `Tests/MCGenerationTests/LoRAExecutorTests.swift`: replace every `#expect(failure.message.contains(kreaModel))` with `#expect(!failure.message.contains(kreaModel))`. User copy must not carry engine ids. Leave the `"Pixel art"` and `"at most 8"` expectations as they are (the new `.loraLimitExceeded` text still contains "at most 8").
3. `Sources/MCApp/ViewState.swift`, `JobItem`: add `public var loraIDs: [String]` and `public var loraNames: [String]` with defaults `[]` in `init` (add parameters `loraIDs: [String] = [], loraNames: [String] = []` at the end).
4. `Sources/MCApp/AppModel+Projection.swift`, `placeholder(for:canMoveUp:canMoveDown:)`: pass `loraIDs: job.request.loras?.map(\.id) ?? []` and `loraNames: job.request.loras?.map(\.name) ?? []`.
5. `Sources/MCApp/CanvasView.swift`, `FailureCard` (I03): in the button `HStack`, before "Try Again", add:

   ```swift
   if !job.canRetry, !job.loraIDs.isEmpty {
       Button("Remove LoRAs from Stack") {
           for id in job.loraIDs { model.removeFromLoRAStack(id: id) }
           let names = job.loraNames.map { "\"\($0)\"" }.joined(separator: ", ")
           model.loraNotice = "Removed \(names) from the stack. Press Generate to try again."
           model.selection = model.canvasFallbackImageID
       }
       .buttonStyle(.borderedProminent)
   }
   ```

   `loraNotice` is an internal `var` on `AppModel`, visible from `MCApp`.
6. Test, in `Tests/MCAppTests/FailureCardTests.swift` (created by I03): `aRejectedLoRAIsListedOnTheFailedJob`. Use `LoRAStackTests`' `importLoRA` helper to stack one LoRA, and a script that answers the generation with `.init(status: 400, body: Data(#"{"error":{"message":"no modules matching","type":"invalid_request_error"}}"#.utf8), tail: nil)`. Wait for `model.selectedFailedJob`; expect `canRetry == false` and `loraIDs` to contain the LoRA's id. Then call `model.removeFromLoRAStack(id:)` for it and expect `model.loraStack.isEmpty`.
7. Format the touched files.

## Do not touch

- `Executor`'s retry without always-on LoRAs (D44) and the "names only the user's LoRAs" rule.
- `LoRAFit` and the pre-check.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0, including the edited `LoRAExecutorTests` and the new test (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. `rg -n 'modelID\)' Sources/MCGeneration/FailureMapping.swift` prints no line inside a `message:` string.

No live screenshot: the engine rejection cannot be produced on demand with the installed LoRAs. The `ImageRenderer` approach from I03 step 7 may be reused to render the card with `loraIDs` set. If you do, attach `I04_card_light.png`.

## Resolution

Done on branch `work/lora-rejection-i04` (uncommitted; the orchestrator commits). The four LoRA failure messages lost the raw engine model id; `modelID` stays a payload of `ExecutorError`'s three LoRA cases and is simply no longer read by `FailureMapping`. `JobItem` carries `loraIDs` and `loraNames`, filled by `placeholder(for:canMoveUp:canMoveDown:)` from `job.request.loras`, which holds only the user's LoRAs, so the copy and the notice can never name an always-on one. `FailureCard` offers **Remove LoRAs from Stack** (`.borderedProminent`) when the failure cannot be retried and at least one of the job's LoRAs is still on the composer stack; the action removes every LoRA the job carried, writes the stack notice and returns the canvas to the kept image.

Differs from the edit steps in four places:

- The button is gated on the stack still holding one of the job's LoRAs, not just on the job having carried them, so it is gone once the user has removed them by hand (new test `removingTheLoRAByHandTakesTheStackRemovalAway`).
- The predicate and the action are two functions on `AppModel` in a new `Sources/MCApp/AppModel+LoRARejection.swift` (`offersRemoveRejectedLoRAs(for:)`, `removeRejectedLoRAs(from:)`) rather than inline in the view, so the non-retryable and still-stacked rule is testable without AppKit. No stored property was added to `AppModel.swift`.
- The notice names only the LoRAs still on the stack when the button is pressed, and the action does nothing when nothing is left, so it can never read "Removed  from the stack." The button removes every LoRA the job carried anyway, because the engine's refusal does not say which one it rejected.
- The canvas returns through `dismissFailureCard()`, not `selection = canvasFallbackImageID`, so the kept image is shown only while it is still in the gallery.

Tests: `LoRAExecutorTests`' rejection test is now `engineRejectingALoRANamesTheLoRAWithoutTheModelAndIsNotRetryable`, and its assertion plus the missing-LoRA, changed-LoRA and limit assertions flip to "the message does not contain the model id"; the limit test gained that assertion. `FailureCardTests` gained `aRejectedLoRAIsListedOnTheFailedJob`, `removeLoRAsFromStackTakesEveryLoRATheJobCarriedAndNamesThem`, `aFailureThatCarriedNoLoRAsOffersNoStackRemoval`, `aRetryableFailureOffersTryAgainAndNoStackRemoval` and `removingTheLoRAByHandTakesTheStackRemovalAway`. All the existing `FailureCardTests` and `LoRAExecutorTests` tests pass unchanged otherwise.

Exercised: `swift build`, `swift test` (269 tests, 28 suites, all pass), `swift format lint --strict` over every tracked Swift file (prints nothing), and `scripts/check-file-size.mjs` over the changed files (exit 0; `AppModel.swift` untouched).

Not run: the live engine rejection. No LoRA installed here passes the header pre-check and then fails in the engine, so the one-click recovery path has only been driven with the stub engine returning the engine's real 400 body. No `I04_card_light.png` was rendered, so the card's layout with the longer non-retryable copy (`loraChanged`, `loraLimitExceeded`) and its third button is unchecked visually; the message text keeps I03's `.body` full-width treatment, so it wraps rather than truncates at the card's 460 pt maximum. `xcodegen`/`xcodebuild` and the GUI smoke are left to the orchestrator.

