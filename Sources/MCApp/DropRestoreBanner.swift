import SwiftUI
import UniformTypeIdentifiers

/// Canvas drop handling for drop-to-restore (HLD D38). Only the first dropped file is used (R13).
@MainActor
enum CanvasDrop {
    static func handle(_ providers: [NSItemProvider], model: AppModel) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard let first = fileProviders.first else { return false }
        let extra = fileProviders.count > 1 ? "Only the first file was used." : nil
        Task {
            let url = await LoRADrop.fileURL(of: first)
            await model.restoreFromDroppedImage(url: url, extraNote: extra)
        }
        return true
    }
}

/// The warning or info line over the canvas after a drop. Dismissible; the next drop or Generate clears it.
struct DropRestoreBanner: View {
    let notice: DropNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: MCSpacing.regular) {
            Image(
                systemName: notice.level == .warning
                    ? "exclamationmark.triangle.fill" : "info.circle.fill"
            )
            .foregroundStyle(notice.level == .warning ? MCTone.warning : MCTone.selection)
            .accessibilityHidden(true)
            Text(notice.message)
                .font(.mcSupporting)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(MCSpacing.group)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MCRadius.card))
        .padding(MCSpacing.group)
        .accessibilityElement(children: .contain)
    }
}
