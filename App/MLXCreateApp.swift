import AppKit
import MCApp
import MCEngine
import Observation
import SwiftUI

@main
struct MLXCreateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let launch: LaunchState

    init() {
        Self.enforceSingleInstance()
        let state = LaunchState()
        launch = state
        Task { await state.open() }
    }

    /// D28: the first instance holds `Engine/app.lock` for its whole life. A second instance brings the running app
    /// forward and quits before it opens the library or touches the engine.
    private static func enforceSingleInstance() {
        do {
            let support = try EnginePaths.defaultAppSupport()
            try InstanceLock.acquire(at: EnginePaths.appLockURL(appSupport: support))
        } catch InstanceLock.Failure.heldByAnotherInstance {
            let me = ProcessInfo.processInfo.processIdentifier
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first { $0.processIdentifier != me }?
                .activate()
            exit(0)
        } catch {
            NSLog("mlx-create: single-instance lock unavailable: %@", error.localizedDescription)
        }
    }

    var body: some Scene {
        Window("mlx-create", id: "main") {
            switch launch.phase {
            case .loading:
                LaunchLoadingView()
            case .ready(let model):
                MainWindow(model: model)
            case .failed(let error):
                LaunchFailureView(error: error)
            }
        }
        .commands { MainCommands() }
    }
}

/// Where the launch stands. The library opens off the main actor, so the window shows a loading view until the model is ready (R15).
@MainActor
@Observable
final class LaunchState {
    enum Phase {
        case loading
        case ready(AppModel)
        case failed(Error)
    }

    private(set) var phase: Phase = .loading

    func open() async {
        do {
            let model = try await AppModel.live()
            AppDelegate.model = model
            phase = .ready(model)
        } catch {
            phase = .failed(error)
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

    /// One window (D28, D33): closing it quits, and the queue resumes on the next launch (D29).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Shown while the library opens. The open runs off the main actor, so this is all the window has to show (R15).
private struct LaunchLoadingView: View {
    var body: some View {
        VStack(spacing: MCSpacing.group) {
            ProgressView()
            Text("Opening library…")
                .foregroundStyle(.secondary)
        }
        .padding(MCSpacing.emptyState)
        .frame(minWidth: 480, minHeight: 200)
    }
}

/// Shown instead of the window when the app cannot be assembled (for example, the library cannot be opened).
private struct LaunchFailureView: View {
    let error: Error

    var body: some View {
        VStack(spacing: MCSpacing.group) {
            Text("mlx-create could not start")
                // no token: a plain title2 has no token; it is not a sheet or empty-state title
                .font(.title2)
            Text(error.localizedDescription)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
        }
        .padding(MCSpacing.emptyState)
        .frame(minWidth: 480, minHeight: 200)
    }
}
