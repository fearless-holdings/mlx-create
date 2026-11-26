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
    /// Empty-state inset, and the content inset of single-purpose sheets.
    static let emptyState: CGFloat = 24
}

/// Corner radii. Badges use `Capsule()`.
enum MCRadius {
    /// Text editors, fields and thumbnails up to 64 pt.
    static let field: CGFloat = 6
    /// Cards, banners, gallery tiles and queue cells.
    static let card: CGFloat = 10
    /// Floating panels over content, like the Chat container (D54).
    static let panel: CGFloat = 14
}

enum MCStroke {
    /// The ring of a selected tile or cell, and the drop-target ring.
    static let selection: CGFloat = 3
    /// A field's outline.
    static let hairline: CGFloat = 1
}

enum MCSize {
    static let emptyStateSymbol: CGFloat = 44
    static let civitaiThumbnail: CGFloat = 64
    static let tileMenuButton: CGFloat = 24
    /// The smallest hit area a button may offer, whatever its glyph's size (P04, P05).
    static let minHitTarget: CGFloat = 28
    /// Name and confirmation sheets.
    /// The share of the window a list sheet (Models browser, LoRA library) targets (N2-5).
    static let sheetWindowFraction: CGFloat = 0.7
    static let sheetNarrow: CGFloat = 360
    /// License, enhancer and other single-purpose sheets.
    static let sheetStandard: CGFloat = 500
    static let emptyStateMaxWidth: CGFloat = 520
    /// The Chat container's width (D54, R2: "about 700 pt").
    static let chatContainerWidth: CGFloat = 700
    /// The fraction of the window's height an unfurled conversation takes (D54, R3: "two thirds").
    static let chatUnfurledFraction: CGFloat = 2.0 / 3.0
    /// The tallest a license text inside a chat download card grows (KTD15).
    static let chatLicenseTextHeight: CGFloat = 120
    /// The Chat setup screen's content column (D60).
    static let chatSetupMaxWidth: CGFloat = 520
    /// The Chat setup screen's hero symbol.
    static let chatSetupSymbol: CGFloat = 56
    /// The tallest a license summary grows inside a Settings list row.
    static let licenseSummaryHeight: CGFloat = 120
}

/// Shadows. Panels floating over content use `panel*`; the image on the studio backdrop uses `image*`;
/// nothing else casts one.
enum MCShadow {
    /// The Chat container's shadow radius.
    static let panelRadius: CGFloat = 16
    /// The Chat container's shadow offset.
    static let panelY: CGFloat = 6
    /// The Chat container's shadow opacity.
    static let panelOpacity: Double = 0.18
    /// The shadow lifting an image off the ``MCTone/studio`` backdrop: radius.
    static let imageRadius: CGFloat = 24
    /// The image shadow's offset.
    static let imageY: CGFloat = 8
    /// The image shadow's opacity in dark mode.
    static let imageOpacityDark: Double = 0.25
    /// The image shadow's opacity in light mode.
    static let imageOpacityLight: Double = 0.15
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
    /// File paths and other identifiers shown as metadata.
    static let mcMetadataMonospaced = Font.caption.monospaced()
    /// Badge text.
    static let mcBadge = Font.caption.weight(.semibold)
}

/// Semantic colours. Text uses `.primary` for anything essential and `.secondary` only for supplementary metadata;
/// the tones below colour SF Symbols, fills, shadows and rings, never text (V02).
enum MCTone {
    static let critical = Color.red
    static let warning = Color.orange
    static let success = Color.green
    static let selection = Color.accentColor
    static let cardFill = HierarchicalShapeStyle.quaternary
    static let separator = Color(nsColor: .separatorColor)
    static let textBackground = Color(nsColor: .textBackgroundColor)
    static let controlBackground = Color(nsColor: .controlBackgroundColor)
    /// The colour every image shadow uses; its strength lives in ``MCShadow``'s opacity tokens.
    static let imageShadow = Color.black
    /// The neutral "studio" backdrop behind the canvas and the large view (N2-4): it stays out of the picture's way.
    static let studio = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.11, alpha: 1)
                : NSColor(white: 0.94, alpha: 1)
        }
    )
    /// The 1 pt halo just outside the selection ring (N2-1): Safelight alone reads 1.78:1 against the dark
    /// sidebar material, so the ring carries a contrasting edge that keeps the whole outline >= 3:1.
    static let selectionHalo = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.9)
                : NSColor(white: 0, alpha: 0.55)
        })
}

extension View {
    /// The selected-tile or queue-cell ring (N2-1): the accent ring plus a 1 pt halo flush outside it, so the
    /// outline keeps >= 3:1 against the column background in both appearances.
    func mcSelectionRing(_ isSelected: Bool, cornerRadius: CGFloat = MCRadius.card) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(isSelected ? MCTone.selection : Color.clear, lineWidth: MCStroke.selection)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .inset(by: -(MCStroke.selection / 2 + MCStroke.hairline / 2))
                .stroke(isSelected ? MCTone.selectionHalo : Color.clear, lineWidth: MCStroke.hairline)
        )
    }
}
