import SwiftUI

/// One line of engine status above the canvas (U8 step 7). Shown only when ``AppModel/banner`` is non-nil.
struct EngineStatusBanner: View {
    let banner: EngineBanner

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .accessibilityElement(children: .combine)
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
