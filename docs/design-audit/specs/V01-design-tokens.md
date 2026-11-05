# V01 · One design-token file for spacing, radii, type and colour

| | |
|---|---|
| Tag | VISUAL |
| Severity (Nielsen 0–4) | 2, minor on its own; it is what makes V02, V05 and V06 cheap and keeps them from drifting again |
| Frequency | Every screen |
| Heuristics | H4 Consistency and standards; H8 Aesthetic and minimalist design |
| User task | All |
| Strategy metric | Indirect: a calmer, more consistent UI is the "Apple-like" quality the user is buying instead of Draw Things |
| HLD decisions | No D* change. A plain `enum` namespace, not a protocol (AGENTS.md: "Prefer boring, explicit code over abstraction") |
| Size | M (token file: S; full migration: M) |
| Depends on | Create the file any time. **Migrate `GenerationPanel`, `ModelChip`, `CanvasView`, `QueueStripView`, `EmptyModelsView` and `LoRASection` only after S01, S02, S03, S06, I02, I03 and I05 land**, because those specs rewrite most of those call sites. Sheets (`LicenseSheet`, `EnhancerInstallSheet`, `CollectionNameSheet`, `ShelfLicenseSheet`, `CivitaiLicenseSheet`) and `GalleryView` can migrate at once |

## Evidence: inventory of hard-coded styling in `Sources/MCApp` and `App/` (commit 633e737)

Produced with the inventory script in the audit's working notes (it scans every `.swift` file for the patterns below). Counts:

| Kind | Uses | Distinct values | Values |
|---|---|---|---|
| `.font(…)` | 139 | 16 | `.caption` ×60, `.callout` ×41, `.headline` ×6, `.caption2` ×6, `.title3.bold()` ×4, `.title2.bold()` ×4, `.caption.bold()` ×4, `.body` ×4, `.caption.monospaced()` ×2, `.callout.bold()` ×2, `.title2`, `.title3`, `.body.monospaced()`, `.body.weight(.medium)`, `.system(size: 40)`, `.system(size: 12, weight: .semibold)` |
| `.padding(…)` | 85 | 25 | 12 ×14, 6 ×7, `.vertical 4` ×7, `.horizontal 12` ×6, `.horizontal 6` ×6, 24 ×4, `.horizontal 5` ×4, `.vertical 1` ×4, 8 ×4, 16 ×3, 20 ×3, 10 ×3, `.vertical 6` ×3, `.vertical 2` ×3, 32 ×2, 4 ×2, `.bottom 8` ×2, `.bottom 10`, `.vertical 3`, `.horizontal 10`, `.horizontal 11`, `.vertical 7`, `.top 2`, `.leading 4`, `.vertical 8` |
| Stack `spacing:` | 101 | 10 | 8 ×25, 4 ×15, 6 ×15, 12 ×13, 2 ×11, 0 ×9, 10 ×7, 14 ×3, 3 ×2, 1 ×1 |
| `cornerRadius:` | 18 | 3 | 8 ×10, 6 ×7, 10 ×1; plus `Capsule()` ×6 |
| Colour literals | 48 | 17 | `.foregroundStyle(.red)` ×10, `Color.accentColor` ×8, `.quaternary` ×8, `Color.clear` ×3, `Color(nsColor: .separatorColor)` ×3, `.foregroundStyle(.orange)` ×2, `.tertiary` ×2, `Color(nsColor: .controlBackgroundColor)` ×2, `Color.secondary` ×2, `.foregroundStyle(.green)`, `Color.orange`, `.quaternary.opacity(0.5)`, `tint.opacity(0.12)`, `.foregroundStyle(.white)`, `.black.opacity(0.7)`, `Color(nsColor: .textBackgroundColor)`, `Color.red` |
| `.foregroundStyle(.secondary)` | 86 | 1 | 14 in `LoRALibraryView`, 12 in `CivitaiBrowseView`, 9 in `InstallRow`, 8 in `GenerationPanel`, … |
| `lineWidth:` | 4 | 2 | 3 ×3 (gallery tile, queue cell, canvas drop ring), 2 ×1 (LoRA drop ring) |
| `controlSize` | 16 | 3 | `.small` ×14, `.mini`, `.large` |

Where the inconsistencies are:

- **Sheets.**
  - Titles: `.title2.bold()` (Models, LoRAs, license, enhancer); `.title3.bold()` (Civitai and shelf license); `.headline` (collection name).
  - Insets: 16 (`ModelBrowserView`, `LoRALibraryView` headers); 20 (`CollectionNameSheet`, `ShelfLicenseSheet`, `CivitaiLicenseSheet`); 24 (`LicenseSheet`, `EnhancerInstallSheet`).
  - Widths: 340, 480, 480, 500, 520.
- **Badges.** Three hand-made capsules:
  - `InstallRow`: `.caption.bold()`, padding 6/2, `.quaternary` or `accentColor.opacity(0.2)`.
  - `LoRALibraryRow` and `CivitaiResultRowView`: `.caption2`, padding 5/1, `.quaternary`.
- **Cards.**
  - Radius 10 (`EmptyModelsView`), 8 (`EnhanceResultCard`, `DropRestoreBanner`, import summary).
  - Fills `.quaternary.opacity(0.5)`, `.quaternary`, `controlBackgroundColor`, `.regularMaterial`.
- **Error text.** `.red` text in 10 places. Measured 3.57:1 on white and 2.86:1 on `.quaternary` (V02).
- **Small type.** 66 uses of 10 pt (`.caption`/`.caption2`), including failure reasons, status lines, the error line under Generate, and the LoRA "doesn't fit" reasons.
- **Odd spacings.** 1, 3, 5, 7, 10, 11 and 14 pt appear with no rule behind them.

## Target: the token file

Create `Sources/MCApp/Design/MCTokens.swift` with exactly this content (SwiftPM picks up the subfolder):

```swift
import AppKit
import SwiftUI

// Design tokens for every MCApp view (docs/design-audit/specs/V01). A view takes its spacing, radii, type and colour from
// here; a literal number or colour in a view is a review finding. Values are macOS points.

/// Spacing: the gap between two things, or an inset.
enum MCSpacing {
    /// A title and its subtitle line.
    static let hairline: CGFloat = 2
    /// A label and its caption; the inside of a badge.
    static let tight: CGFloat = 4
    /// A symbol and its text; the vertical padding of a list row.
    static let compact: CGFloat = 6
    /// Related controls in one row.
    static let regular: CGFloat = 8
    /// Groups inside a panel; the panel's inset.
    static let group: CGFloat = 12
    /// Card insets; sheet header insets; the canvas inset.
    static let section: CGFloat = 16
    /// Sheet content inset.
    static let sheet: CGFloat = 20
    /// Empty-state and launch-view inset.
    static let emptyState: CGFloat = 24
}

/// Corner radii. Badges use `Capsule()`.
enum MCRadius {
    /// Text editors, fields and thumbnails up to 64 pt.
    static let field: CGFloat = 6
    /// Cards, banners, gallery tiles and queue cells.
    static let card: CGFloat = 10
}

/// Line widths.
enum MCStroke {
    /// The ring of a selected tile or cell, and the drop-target ring.
    static let selection: CGFloat = 3
    /// A field's outline.
    static let hairline: CGFloat = 1
}

/// Fixed sizes that recur.
enum MCSize {
    static let emptyStateSymbol: CGFloat = 44
    static let civitaiThumbnail: CGFloat = 64
    static let tileMenuButton: CGFloat = 24
    /// Name and confirmation sheets.
    static let sheetNarrow: CGFloat = 360
    /// License, enhancer and other single-purpose sheets.
    static let sheetStandard: CGFloat = 500
    static let emptyStateMaxWidth: CGFloat = 520
}

/// Type styles. macOS sizes: body 13, callout 12, headline 13 bold, title2 17, caption 10.
extension Font {
    /// Sheet titles and empty-state titles.
    static let mcSheetTitle = Font.title2.bold()
    /// Row titles and section titles.
    static let mcRowTitle = Font.headline
    /// Prompts, messages and error text.
    static let mcBody = Font.body
    /// Status lines, reasons and explanations: anything the user must read to act.
    static let mcSupporting = Font.callout
    /// Sizes, counts and dates only. Never a reason, a status or an error.
    static let mcMetadata = Font.caption
    /// Badge text.
    static let mcBadge = Font.caption.weight(.semibold)
}

/// Semantic colours. Text uses `.primary` for anything essential and `.secondary` only for supplementary metadata;
/// the tones below colour SF Symbols, fills and rings, never text (V02).
enum MCTone {
    static let critical = Color.red
    static let warning = Color.orange
    static let success = Color.green
    static let selection = Color.accentColor
    static let cardFill = HierarchicalShapeStyle.quaternary
    static let separator = Color(nsColor: .separatorColor)
    static let textBackground = Color(nsColor: .textBackgroundColor)
    static let controlBackground = Color(nsColor: .controlBackgroundColor)
}
```

## Mapping rules for the migration

| Found | Replace with |
|---|---|
| spacing or padding 1, 2, 3 | `MCSpacing.hairline` (badge paddings move into `MCBadge`, V05) |
| 4, 5 | `MCSpacing.tight` |
| 6, 7 | `MCSpacing.compact` |
| 8, 10 between controls in a row or stack | `MCSpacing.regular` |
| 10, 11, 12 as an inset or between groups | `MCSpacing.group` |
| 14, 16 | `MCSpacing.section` |
| 20 | `MCSpacing.sheet` |
| 24, 32 | `MCSpacing.emptyState` |
| `cornerRadius: 6` | `MCRadius.field` |
| `cornerRadius: 8`, `10` | `MCRadius.card` |
| `lineWidth: 2`, `3` on a selection or drop ring | `MCStroke.selection` |
| `.title2.bold()`, `.title3.bold()` on a sheet or empty-state title | `.mcSheetTitle` |
| `.headline`, `.callout.bold()` on a row title | `.mcRowTitle` |
| `.caption`, `.caption2` on a reason, status or error | `.mcSupporting` (and `.primary`, V02) |
| `.caption`, `.caption2` on sizes, counts or dates | `.mcMetadata` |
| `.caption.bold()`, `.caption2` in a capsule | `MCBadge` (V05) |
| `.system(size: 40)` | `.system(size: MCSize.emptyStateSymbol)` |
| `.foregroundStyle(.red)` on text | `.primary` text plus an `MCTone.critical` symbol (V02) |
| `.quaternary` card fill | `MCTone.cardFill` |
| `Color(nsColor: .separatorColor)` | `MCTone.separator` |

`spacing: 0` stays `0`, a deliberate no-gap. `GalleryLayout`'s `inset`, `spacing`, `minSide` and `maxSide` stay AppKit constants; replace their literals with `MCSpacing.group`, `MCSpacing.regular`, 100 and 120.

## Edit steps

1. Create `Sources/MCApp/Design/MCTokens.swift` with the content above. Build: `swift build`.
2. Migrate one file per commit, in the order given under "Depends on", applying the mapping table. In each file, replace every hit of:

   ```
   rg -n '\.padding\([^)]*[0-9]|spacing: [1-9]|cornerRadius: [0-9]|lineWidth: [0-9]|\.font\(\.(caption|callout|headline|title|body|system)|foregroundStyle\(\.(red|orange|green)\)|Color\.(red|orange)|\.quaternary|nsColor: \.' <file>
   ```

   Keep `.font(.body)` on the prompt editor. Keep `controlSize` as it is.
3. After each file, run the standard checks below. The UI must look the same except where the mapping table moves a value by 1–2 pt.
4. Add the rule to `AGENTS.md` under Engineering conventions: "**Design tokens:** views take spacing, radii, type and colour from `Sources/MCApp/Design/MCTokens.swift` (docs/design-audit/specs/V01). A literal spacing, radius, font or colour in a view needs a reason in a comment."

## Do not touch

- System control metrics (`controlSize`, `.buttonStyle`): they are already system tokens.
- `GalleryLayout`'s column-fitting logic.

## Acceptance

Standard checks, all must pass:

1. `swift build` exits 0.
2. `swift test` exits 0 (about 40 s; if past 2 minutes, `pkill -f swiftpm-testing-helper; pkill -f swift-test` and rerun with `--filter`).
3. `git ls-files '*.swift' | xargs swift format lint --strict --configuration .swift-format` prints nothing.
4. `xcodegen generate && xcodebuild -project MLXCreate.xcodeproj -scheme MLXCreate -configuration Debug -derivedDataPath build build` prints `** BUILD SUCCEEDED **`.
5. GUI smoke exits 0.
6. After full migration, this prints nothing (the token file itself is excluded):

   ```
   rg -n 'spacing: [1-9]|cornerRadius: [0-9]|lineWidth: [0-9]|\.font\(\.system\(size: [0-9]|\.font\(\.caption2\)|foregroundStyle\(\.(red|orange|green)\)' Sources/MCApp --glob '!Design/MCTokens.swift'
   ```

7. Before/after captures of the first-launch and populated-gallery states, light and dark, at 1100×692 (capture kit), are attached to the PR. No layout moves by more than 4 pt except where another spec says so.

## Appendix: call sites at commit 633e737

Line numbers move as other specs land. Re-run the `rg` in step 2 to locate them. File: line: kind `value`.

**CanvasView.swift**: 18: radius `8`; 19: color `lineWidth: 3`; 20: padding `4`; 38: font `.title3`; 52: spacing `12`; 66: padding `16`; 106: spacing `4`; 111: font `.caption`; 124: spacing `12`; 126: font `.title3.bold()`; 128: spacing `2`; 130: font `.body.monospaced()`; 133: font `.callout`; 139: padding `24`

**Civitai/CivitaiBrowseView.swift**: 54: spacing `0`; 56: padding `12`; 59: padding `.horizontal, 12`; 60: padding `.bottom, 10`; 66: padding `12`; 89: spacing `8`; 90: spacing `8`; 121: spacing `14`; 139: font `.caption`; 181: spacing `8`; 184: spacing `10`; 197: spacing `10`; 205: padding `12`; 209: spacing `8`; 218: padding `12`; 227: padding `12`; 250: spacing `8`; 253: font `.caption`; 258: font `.caption`; 278: spacing `4`; 279: spacing `8`; 296: font `.caption`; 302: font `.caption`; 303: color `.foregroundStyle(.red)`; 306: font `.caption`; 336: spacing `10`; 338: spacing `3`; 339: spacing `6`; 341: font `.body.weight(.medium)`; 353: font `.caption`; 362: padding `.vertical, 3`; 378: radius `6`; 384: font `.caption2`; 385: padding `.horizontal, 5`; 386: padding `.vertical, 1`; 387: color `.quaternary`; 405: font `.caption`; 406: color `.foregroundStyle(.green)`; 409: font `.caption`; 410: color `.foregroundStyle(.orange)`; 413: font `.caption`; 414: color `.foregroundStyle(.red)`; 418: font `.caption`; 419: color `.foregroundStyle(.red)`; 450: font `.caption`; 462: color `.quaternary`; 467: color `.tertiary)`; 492: spacing `12`; 494: font `.title3.bold()`; 496: font `.callout`; 498: spacing `6`; 501: font `.callout`; 506: font `.caption`; 520: padding `20`

**CollectionMenu.swift**: 58: font `.headline`; 85: spacing `12`; 87: font `.headline`; 93: font `.callout`; 94: color `.foregroundStyle(.red)`; 109: padding `20`

**DropRestoreBanner.swift**: 27: spacing `8`; 32: color `Color.orange`; 35: font `.callout`; 44: padding `10`; 45: radius `8`; 46: padding `12`

**EmptyModelsView.swift**: 11: spacing `12`; 13: font `.system(size: 40)`; 17: font `.title3.bold()`; 19: font `.callout`; 23: spacing `4`; 25: font `.caption.bold()`; 29: padding `12`; 31: radius `10`, color `.quaternary.opacity(0.5)`; 40: font `.callout`; 48: padding `24`

**EngineStatusBanner.swift**: 10: spacing `8`; 11: spacing `8`; 16: font `.callout`; 27: padding `.horizontal, 12`; 28: padding `.vertical, 6`; 30: color `tint.opacity(0.12)`

**EnhanceResultCard.swift**: 24: spacing `8`; 28: padding `10`; 30: radius `8`, color `Color(nsColor: .controlBackgroundColor)`; 31: radius `8`; 42: spacing `4`; 44: font `.callout`; 47: font `.callout`; 53: spacing `4`; 55: font `.body`; 60: spacing `4`; 62: font `.body`; 66: font `.callout`; 74: font `.callout`; 75: color `.foregroundStyle(.red)`; 84: font `.caption`

**EnhancerInstallSheet.swift**: 15: spacing `14`; 17: font `.title2.bold()`; 24: padding `24`; 42: spacing `6`; 44: font `.headline`; 46: font `.callout`; 52: font `.callout`; 56: spacing `6`; 59: font `.callout`; 64: font `.callout`; 65: color `.foregroundStyle(.red)`; 69: font `.callout`

**GalleryView.swift**: 12: spacing `0`; 35: spacing `8`; 71: spacing `6`; 93: padding `8`; 117: spacing `10`; 133: padding `12`; 142: spacing `4`; 143: font `.caption`; 145: font `.callout`, color `.tertiary)`; 172: spacing `4`; 176: font `.caption`; 181: font `.caption`; 187: padding `.horizontal, 10`; 188: padding `.vertical, 6`; 245: radius `8`; 247: radius `8`; 248: color `lineWidth: 3`; 259: font `.system(size: 12, weight: .semibold)`; 260: color `.foregroundStyle(.white)`; 262: radius `6`, color `.black.opacity(0.7)`; 268: padding `6`

**GenerationPanel.swift**: 23: spacing `0`; 40: radius `8`; 41: color `lineWidth: 2`; 42: padding `4`; 52: spacing `12`; 65: padding `12`; 72: font `.body`; 74: padding `6`; 75: radius `6`, color `Color(nsColor: .textBackgroundColor)`; 76: radius `6`, color `Color(nsColor: .separatorColor)`; 81: padding `.horizontal, 11`; 82: padding `.vertical, 7`; 94: spacing `4`; 96: font `.caption`; 100: font `.callout`; 107: padding `8`; 108: radius `6`, color `Color(nsColor: .controlBackgroundColor)`; 109: radius `6`, color `Color(nsColor: .separatorColor)`; 118: spacing `6`; 119: spacing `8`; 122: font `.caption`; 137: font `.caption`; 211: spacing `8`; 240: spacing `8`; 267: spacing `6`; 268: spacing `10`; 279: font `.caption`; 296: font `.caption`; 297: color `.foregroundStyle(.red)`; 301: padding `12`

**LoRALibraryView.swift**: 52: spacing `0`; 53: spacing `12`; 55: font `.title2.bold()`; 70: padding `16`; 91: spacing `0`; 96: padding `12`; 99: padding `.horizontal, 12`; 100: padding `.bottom, 8`; 104: padding `.horizontal, 12`; 105: padding `.bottom, 8`; 111: padding `12`; 137: spacing `10`; 154: spacing `10`; 159: font `.caption`; 175: spacing `8`; 189: spacing `0`; 219: padding `12`; 231: spacing `8`; 235: font `.callout`; 246: spacing `4`; 266: font `.callout`; 268: padding `10`; 269: radius `8`, color `.quaternary`; 273: spacing `8`; 275: font `.caption`; 280: font `.caption`; 302: spacing `8`; 303: spacing `2`; 304: spacing `6`; 310: font `.caption2`; 311: padding `.horizontal, 5`; 312: padding `.vertical, 1`; 313: color `.quaternary`; 317: font `.caption2`; 318: padding `.horizontal, 5`; 319: padding `.vertical, 1`; 320: color `.quaternary`; 324: font `.caption`; 328: font `.caption`; 333: font `.caption`; 345: padding `.vertical, 2`; 381: spacing `12`; 389: font `.callout`; 393: font `.callout`; 404: font `.caption`; 406: spacing `4`; 408: font `.callout`; 410: font `.body`; 412: radius `6`, color `Color(nsColor: .separatorColor)`; 428: padding `12`; 499: spacing `8`; 500: spacing `6`; 502: font `.headline`; 505: font `.caption2`; 506: padding `.horizontal, 5`; 507: padding `.vertical, 1`; 508: color `.quaternary`; 529: font `.callout`; 531: spacing `3`; 536: padding `.top, 2`; 538: font `.callout`; 542: font `.callout`; 548: font `.caption`

**LoRASection.swift**: 19: font `.caption`; 27: font `.caption`; 33: font `.caption`; 61: spacing `4`; 65: font `.caption`; 86: spacing `6`; 96: spacing `2`; 97: spacing `8`; 112: font `.caption`; 120: font `.caption`; 127: font `.caption`; 128: color `Color.red`; 145: spacing `8`; 147: spacing `8`; 159: font `.caption`; 190: font `.caption`; 197: font `.caption`; 199: padding `.leading, 4`

**MainWindow.swift**: 13: spacing `0`; 21: spacing `0`

**ModelChip.swift**: 18: font `.caption`; 28: padding `8`; 56: spacing `2`; 60: padding `6`; 77: padding `.horizontal, 6`; 78: padding `.vertical, 4`; 82: padding `.vertical, 4`; 87: spacing `1`; 90: font `.caption`; 95: padding `.horizontal, 6`; 96: padding `.vertical, 4`; 101: padding `.vertical, 4`; 107: padding `.horizontal, 6`; 108: padding `.vertical, 4`

**Models/InstallRow.swift**: 12: spacing `12`; 13: spacing `4`; 14: spacing `6`; 16: font `.headline`; 19: font `.caption.bold()`; 20: padding `.horizontal, 6`; 21: padding `.vertical, 2`; 22: color `.quaternary`; 26: font `.caption.bold()`; 27: padding `.horizontal, 6`; 28: padding `.vertical, 2`; 34: font `.caption`; 39: font `.caption`; 45: font `.caption`; 46: color `.foregroundStyle(.orange)`; 50: spacing `4`; 54: font `.caption`; 60: padding `.vertical, 6`; 83: font `.callout`; 86: spacing `2`; 89: font `.caption`; 94: font `.callout`; 97: spacing `2`; 99: font `.callout`; 101: font `.caption.monospaced()`; 106: spacing `2`; 108: font `.callout`; 110: font `.caption.monospaced()`; 116: font `.callout`; 120: font `.callout`; 121: color `.foregroundStyle(.red)`

**Models/LicenseSheet.swift**: 11: spacing `14`; 13: font `.title2.bold()`; 15: font `.callout.bold()`; 22: font `.callout`; 25: font `.callout`; 32: font `.callout`; 55: padding `24`; 62: spacing `6`; 64: font `.callout.bold()`; 68: font `.callout`; 71: spacing `8`; 73: spacing `2`; 74: font `.caption.bold()`; 75: font `.caption`

**Models/ModelBrowserView.swift**: 10: spacing `0`; 13: font `.title2.bold()`; 20: padding `16`

**PromptHistoryPopover.swift**: 22: padding `8`; 47: spacing `6`; 54: padding `6`; 59: padding `6`; 63: padding `6`; 66: spacing `2`; 82: spacing `2`; 87: font `.caption`; 96: padding `.horizontal, 6`; 97: padding `.vertical, 4`

**QueueStripView.swift**: 9: spacing `6`; 11: padding `.horizontal, 12`; 13: spacing `8`; 18: padding `.horizontal, 12`; 21: padding `.vertical, 8`; 31: spacing `8`; 62: font `.caption`; 78: spacing `6`; 82: font `.caption2`; 86: padding `6`; 88: radius `8`, color `.quaternary`; 90: radius `8`; 91: color `lineWidth: 3`; 148: font `.caption`; 153: font `.caption`; 156: font `.caption`; 158: font `.caption`; 161: font `.caption`; 162: color `.foregroundStyle(.red)`; 165: font `.caption2`; 171: font `.caption`; 173: font `.caption`

**Shelf/ShelfView.swift**: 60: spacing `12`; 61: spacing `2`; 62: font `.headline`; 64: font `.callout`; 68: font `.caption`; 75: padding `.vertical, 4`; 84: font `.callout`; 93: font `.callout`; 95: spacing `4`; 96: font `.caption`, color `.foregroundStyle(.red)`; 110: spacing `12`; 111: font `.title3.bold()`; 114: font `.callout`; 128: padding `20`

## Resolution

Done in [#43](https://github.com/fearless-holdings/mlx-create/pull/43). `Sources/MCApp/Design/MCTokens.swift` is the spec's file plus one token, `Font.mcMetadataMonospaced`, because `.caption.monospaced()` appeared twice, both on file paths in `InstallRow`. Every view in `Sources/MCApp` takes its spacing, radii, strokes and type from it, and the closing `rg` from the spec prints nothing. The result differs from the spec in these ways:

- **Layout may move.** The author lifted the spec's 4 pt cap, so odd spacings snapped by role to the nearest token. In the captures at 1100×692 the pixel change against the unmigrated build is under 1.1 % of each window in every state, light and dark; nothing clipped.
- **Status colour stays on the text.** Red, orange and green text keep their colour through `MCTone.critical`, `.warning` and `.success`. V02 moves the colour to the symbol; its search commands now look for `MCTone`.
- **10 pt lines stay 10 pt.** Every `.caption` and `.caption2` became `.mcMetadata`, reasons and status lines included. V02 promotes the reasons to `.mcSupporting` and removes the two notes V01 left in `MCTokens.swift` (V02 step 5).
- **Titles moved with their token.** `.title3.bold()` titles (Civitai licence, shelf licence) grew from 15 to 17 pt as `.mcSheetTitle`; `.callout.bold()` row titles grew from 12 to 13 pt as `.mcRowTitle`; the collection-name sheet's title is `.mcRowTitle` with a comment that V06 upgrades it.
- **The two launch views in `App/MLXCreateApp.swift` keep their literals.** The app target cannot see MCApp's internal tokens; making the tokens `public` for two views was not worth the surface. A comment says so.
- **Sheet widths and `MCSize.sheetNarrow` and `.sheetStandard` are untouched**; V06 assigns them.

Literals kept with a `// no token:` reason: the gallery tile chip's white glyph and black fill, `.caption.bold()` on the licence-notice name, `.caption.weight(.semibold)` on the "More options" chevron, `.title3` and `.title2` and `.body.monospaced()` in `CanvasView`, and `.body.weight(.medium)` on the Civitai result name. `.font(.body)` on the prompt editor stays with its own comment.

Exercised: `swift build`, `swift test` (295 tests), `swift format lint --strict` over all tracked Swift files, `xcodebuild` (BUILD SUCCEEDED), GUI smoke (exit 0), and seven before and after captures in light and dark with the capture kit: first launch, populated gallery, image selected, Models sheet, LoRA sheet, model chip popover, prompt-history popover. Not exercised: Increase Contrast and Reduce Transparency.
