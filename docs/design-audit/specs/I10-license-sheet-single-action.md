# I10 · License sheets: one "Accept and Download" button, the same on every sheet

| | |
|---|---|
| Tag | INTERACTION |
| Severity (Nielsen 0–4) | 2, minor: two actions (checkbox, then Install) on the first-run path; the three license sheets ask for acceptance three different ways; the Qwen sheet reads "version Release Date: September 20, 2026" |
| Frequency | Every model, shelf LoRA and Civitai LoRA download; on the first-run path for every user |
| Heuristics | H4 Consistency and standards; H8 Aesthetic and minimalist design |
| User task | (a) first launch to first kept image; (d) add a LoRA |
| Strategy metric | Time to first kept image |
| HLD decisions | No D* change. D20 and D26 require that the license is shown and **accepted before the download starts**. A button labelled "Accept and Download" is an explicit acceptance, and `CivitaiLicenseSheet` already works this way. The checkbox is plan-level (KTD10), not an HLD decision. The acceptance record (license id, version, time) is unchanged. If the release-prerequisite legal read (D26, D31) asks for a separate checkbox, keep only steps 3 and 4 below |
| Size | S |
| Depends on | none |

## Evidence

- Screenshots: `screens/05b-license-sheet_small_light.png` (Qwen: checkbox + disabled Install; the subtitle reads "Qwen Research License Agreement, version Release Date: September 20, 2026"); `screens/05c-license-sheet-flux_small_light.png`; `screens/10c-shelf-license_small_light.png` (shelf: checkbox + "Download and add").
- Code:
  - `Sources/MCApp/Models/LicenseSheet.swift`: `Toggle(…, isOn: $license.accepted)` and `Button("Install")` `.disabled(!license.canConfirm)`; subtitle `"\(pending.content.licenseName), version \(pending.content.version)"`.
  - `Sources/MCApp/Shelf/ShelfView.swift`, `ShelfLicenseSheet`: a local `@State var accepted` toggle and `Button("Download and add")`.
  - `Sources/MCApp/Civitai/CivitaiBrowseView.swift`, `CivitaiLicenseSheet`: no checkbox, `Button("Accept and download")` as the default action.
- HIG, Buttons: "use a button that has a prominent visual style for the most likely action".

## Target behavior

All three sheets end with the same two buttons: **Cancel** (`.cancelAction`) and **Accept and Download** (`.defaultAction`, `.borderedProminent`). There is no checkbox. Pressing Accept and Download records the acceptance and starts the download, as confirm does today. Above the buttons, one line in `.callout`, `.primary`: "By choosing Accept and Download you accept the \(licenseName)" (model sheet; when there are D45 notices, add " and the notices above"), or "By choosing Accept and Download you accept this license" (shelf and Civitai).

Model sheet subtitle: `"\(licenseName), version \(version)"` when `version` starts with a digit, else `"\(licenseName) (\(version))"`.

## Edit steps

1. `Sources/MCApp/Models/LicenseSheet.swift`:
   - Delete the `Toggle(…)` and put in its place:

     ```swift
     Text(
         pending.notices.isEmpty
             ? "By choosing Accept and Download you accept the \(pending.content.licenseName)."
             : "By choosing Accept and Download you accept the \(pending.content.licenseName) and the notices above."
     )
     .font(.callout)
     .fixedSize(horizontal: false, vertical: true)
     ```

   - Replace the `Button("Install") { browser.confirmLicense() }` block with:

     ```swift
     Button("Accept and Download") {
         license.accepted = true
         browser.confirmLicense()
     }
     .keyboardShortcut(.defaultAction)
     .buttonStyle(.borderedProminent)
     ```

     `confirmLicense()` still guards on `license.canConfirm`, which is `pending != nil && accepted` (`LicensePrompt`, `ModelBrowserModel.swift`). Setting `accepted` first satisfies it.
   - Replace the subtitle `Text("\(pending.content.licenseName), version \(pending.content.version)")` with `Text(Self.licenseTitle(name: pending.content.licenseName, version: pending.content.version))` and add:

     ```swift
     static func licenseTitle(name: String, version: String) -> String {
         version.first?.isNumber == true ? "\(name), version \(version)" : "\(name) (\(version))"
     }
     ```

2. `Sources/MCApp/Shelf/ShelfView.swift`, `ShelfLicenseSheet`: delete `@State private var accepted` and the `Toggle`; add the `.callout` line "By choosing Accept and Download you accept this license."; rename the button to "Accept and Download", remove its `.disabled(!accepted)`, and add `.buttonStyle(.borderedProminent)`.
3. `Sources/MCApp/Civitai/CivitaiBrowseView.swift`, `CivitaiLicenseSheet`: rename `Button("Accept and download")` to `Button("Accept and Download")` and add `.buttonStyle(.borderedProminent)`. Replace the caption "Your acceptance and the time you accepted are recorded with the LoRA." with the same `.callout` line as the shelf sheet plus a second sentence: "The time you accepted is recorded with the LoRA."
4. Tests: `rg -n "accepted = true|canConfirm" Tests/MCAppTests` finds the tests that drive the license prompt (e.g. `ModelBrowserTests`, `ModelBrowserNoticesTests`). They set `license.accepted` directly and must still pass unchanged. Add one test to `Tests/MCAppTests/ModelBrowserTests.swift`: `licenseTitleReadsNaturally`, which checks `LicenseSheet.licenseTitle(name: "Apache License 2.0", version: "2.0")` contains "version 2.0" and `LicenseSheet.licenseTitle(name: "Qwen Research License Agreement", version: "Release Date: September 20, 2026")` does not contain "version Release".
5. Format the touched files.

## Do not touch

- `ModelBrowserModel.confirmLicense()`, the acceptance record (`LicenseAcceptance`), per-version re-acceptance (D26), and the D45 notices content and wording (D46).
- License text and summaries (catalog data).

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. `rg -n "I have read and accept" Sources` prints nothing.

With the capture kit and an empty home (no download is started):

6. Open the model browser, press Install on Qwen-Image 2.1 Turbo. `ax dump` of the sheet shows no `AXCheckBox`, an enabled `AXButton` "Accept and Download", and a static text containing "(Release Date: September 20, 2026)". Press Cancel.
7. Captures `I10_model_license_light.png` and `I10_model_license_dark.png` are attached to the PR.

## Resolution

Done on branch `feat/audit-first-run-path`, commit `9903a19` (PR pending). The checkbox is gone from all three sheets. This takes the default in the HLD row: the release-prerequisite legal read (D26, D31) has not happened, and if it asks for a separate checkbox, revert this commit or keep only edit steps 3 and 4. The stale "checkbox" comments in `LicensePrompt` and `confirmLicense()` were corrected in the I01 commit `8ed5201`, because that commit already changes `ModelBrowserModel.swift`. Exercised: `swift build`, `swift test` (including `licenseTitleReadsNaturally`), `swift format lint --strict`, the Debug `xcodebuild`, GUI smoke (exit 0), and checks 6 and 7. The model licence sheet's `ax dump` has no checkbox, an enabled `Accept and Download`, and "(Release Date: September 20, 2026)". Light and dark captures are in `/tmp/mc-audit-shots/` (`I10_model_license_*.png`). The vision read found `Accept and Download` accent-filled (`#3478F6`) in both modes, with no toggle. Not exercised: the Shelf and Civitai sheets in the GUI (they share the same edit but need a LoRA to open).
