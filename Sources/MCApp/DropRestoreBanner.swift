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
        Task {
            guard let url = await LoRADrop.fileURL(of: first) else { return }
            await model.restoreFromDroppedImage(url: url)
            if fileProviders.count > 1, let notice = model.dropNotice {
                model.dropNotice = DropNotice(
                    level: notice.level, message: notice.message + " Only the first file was used.")
            }
        }
        return true
    }
}

/// The warning or info line over the canvas after a drop. Dismissible; the next drop or Generate clears it.
struct DropRestoreBanner: View {
    let notice: DropNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(
                systemName: notice.level == .warning
                    ? "exclamationmark.triangle.fill" : "info.circle.fill"
            )
            .foregroundStyle(notice.level == .warning ? Color.orange : Color.accentColor)
            .accessibilityHidden(true)
            Text(notice.message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
        .accessibilityElement(children: .contain)
    }
}
