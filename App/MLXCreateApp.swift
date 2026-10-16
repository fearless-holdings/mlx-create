import AppKit
import MCApp
import SwiftUI

@main
struct MLXCreateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let launch: Result<AppModel, Error>

    init() {
        launch = Result { try AppModel.live() }
        if case .success(let model) = launch {
            AppDelegate.model = model
        }
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

/// Stops the engine before the app quits (LLD §5.8). AppKit asks the delegate, not the App struct, so the App
/// hands over the model it created.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
