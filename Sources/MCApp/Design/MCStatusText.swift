import SwiftUI

/// A status line: a coloured symbol and primary text (V02). The colour is on the symbol only, so the text keeps
/// full contrast in light, dark and Increase Contrast.
struct MCStatusText: View {
    enum Kind { case critical, warning, success }
    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MCSpacing.tight) {
            Image(systemName: symbol)
                .foregroundStyle(tone)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.mcSupporting)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch kind {
        case .critical: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    private var tone: Color {
        switch kind {
        case .critical: MCTone.critical
        case .warning: MCTone.warning
        case .success: MCTone.success
        }
    }
}
