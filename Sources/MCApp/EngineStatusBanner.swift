import SwiftUI

/// One line of engine status above the canvas (U8 step 7). Shown only when ``AppModel/banner`` is non-nil.
/// A failed engine offers a restart, because the supervisor stops retrying once its budget is spent.
struct EngineStatusBanner: View {
    let banner: EngineBanner
    let onRestart: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if case .failed = banner {
                Button("Restart engine", action: onRestart)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }

    private var text: String {
        switch banner {
        case .starting:
            "Starting the image engine. Generate will wait for it."
        case .warmingModel(let name):
            "Loading \(name). Generate will wait for the model."
        case .restarting:
            "The image engine stopped and is restarting. Queued jobs wait for it."
        case .failed(let message):
            "Image engine unavailable: \(message)"
        }
    }

    private var symbol: String {
        switch banner {
        case .starting, .warmingModel: "hourglass"
        case .restarting: "arrow.clockwise"
        case .failed: "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch banner {
        case .starting, .warmingModel, .restarting: .orange
        case .failed: .red
        }
    }
}
