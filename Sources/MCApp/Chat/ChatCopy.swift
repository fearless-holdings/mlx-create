import Foundation

/// The sentences Chat-mode error messages show (KTD17). Each names one way forward; views quote them verbatim.
enum ChatCopy {
    /// The engine is down and nothing can plan or render.
    static let engineDown = "The image engine isn't running. Restart it from the banner at the top, then try again."
    /// The agent model or an image model is missing.
    static let notReady =
        "Chat needs its model and an image model before it can make pictures. Open Image ▸ Models… to install them."
    /// The reply could not be used even after one retry.
    static let couldNotPlan = "I couldn't work out how to make that. Try saying it another way."
    /// The chat call ran out of memory.
    static let noMemoryToThink =
        "There isn't enough free memory to work on this right now. Quit apps you aren't using, then try again."
    /// The agent model's load failed.
    static let agentNotLoaded = "The chat model couldn't be loaded. Try again."
}
