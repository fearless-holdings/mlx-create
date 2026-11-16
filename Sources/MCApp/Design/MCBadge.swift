import SwiftUI

/// A small capsule label (V05). Never wraps.
struct MCBadge: View {
    enum Tone { case neutral, accent }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.mcBadge)
            .lineLimit(1)
            .padding(.horizontal, MCSpacing.compact)
            .padding(.vertical, MCSpacing.hairline)
            .background(background, in: Capsule())
            .fixedSize()
    }

    private var background: AnyShapeStyle {
        switch tone {
        case .neutral: AnyShapeStyle(MCTone.cardFill)
        case .accent: AnyShapeStyle(Color.accentColor.opacity(0.2))
        }
    }
}
