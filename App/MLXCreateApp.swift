import MCApp
import SwiftUI

@main
struct MLXCreateApp: App {
    private let launch: Result<AppModel, Error>

    init() {
        launch = Result { try AppModel.live() }
    }

    var body: some Scene {
        WindowGroup {
            switch launch {
            case .success(let model):
                MainWindow(model: model)
            case .failure(let error):
                LaunchFailureView(error: error)
            }
        }
    }
}

/// Shown instead of the window when the app cannot be assembled (for example, the library cannot be opened).
private struct LaunchFailureView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 12) {
            Text("mlx-create could not start")
                .font(.title2)
            Text(error.localizedDescription)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 200)
    }
}
