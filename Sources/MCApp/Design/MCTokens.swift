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
    /// Name and confirmation sheets.
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
}

/// Shadows. Panels floating over content use `panel*`; nothing else casts one.
enum MCShadow {
    /// The Chat container's shadow radius.
    static let panelRadius: CGFloat = 16
    /// The Chat container's shadow offset.
    static let panelY: CGFloat = 6
    /// The Chat container's shadow opacity.
    static let panelOpacity: Double = 0.18
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
