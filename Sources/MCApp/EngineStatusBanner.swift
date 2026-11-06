import SwiftUI

/// Engine status above the canvas (U8 step 7, audit I06). Shown only when ``AppModel/banner`` is non-nil.
/// A failed engine offers a restart, because the supervisor stops retrying once its budget is spent.
struct EngineStatusBanner: View {
    let banner: EngineBanner
    let onRestart: () -> Void

    var body: some View {
        HStack(spacing: MCSpacing.regular) {
            HStack(spacing: MCSpacing.regular) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.mcSupporting)
                    .foregroundStyle(.primary)
                    .lineLimit(isFailed ? 2 : 1)
                    .truncationMode(isFailed ? .tail : .middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if case .failed = banner {
                Button("Restart Engine", action: onRestart)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, MCSpacing.group)
        .padding(.vertical, MCSpacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
    }

    private var isFailed: Bool {
        if case .failed = banner { return true }
        return false
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
            message
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
        case .starting, .warmingModel, .restarting: MCTone.warning
        case .failed: MCTone.critical
        }
    }
}
