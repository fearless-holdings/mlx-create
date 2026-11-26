import Foundation

/// The sentences Chat-mode error messages show (KTD17). Each names one way forward; views quote them verbatim.
enum ChatCopy {
    /// The engine is down and nothing can plan or render.
    static let engineDown = "The image engine isn't running. Restart it from the banner at the top, then try again."
    /// The agent model or an image model is missing and no better diagnosis applies.
    static let notReady =
        "Chat needs its model and an image model before it can make pictures. Open Image ▸ Models… to install them."
    /// Every fitting image model is already being downloaded; the user should wait rather than open the browser.
    static let imageModelDownloading =
        "Chat can make pictures once the image model download finishes. You can keep using MLX Create meanwhile."
    /// There is no usable image model and installs are off, so opening the browser cannot help.
    static let imageInstallsUnavailable =
        "Chat needs an image model before it can make pictures, but the model catalog could not be verified, so MLX Create cannot install one yet. Check your connection; MLX Create tries again when it refreshes the catalog."
    /// The reply could not be used even after one retry.
    static let couldNotPlan = "I couldn't work out how to make that. Try saying it another way."
    /// The chat call ran out of memory.
    static let noMemoryToThink =
        "There isn't enough free memory to work on this right now. Quit apps you aren't using, then try again."
    /// The agent model's load failed.
    static let agentNotLoaded = "The chat model couldn't be loaded. Try again."
    /// The first line of a fresh install's conversation (D60).
    static let greeting = "Hi. Tell me what picture you want and I'll make it."

    /// A card's install did not finish — the user cancelled it or the app quit mid-download. Accept retries it.
    static let downloadInterrupted = "The download was interrupted."
    /// The D61 notice, shown by the card view verbatim.
    static let adultOff =
        "Adult content is switched off, so this was made without the adult add-ons. Turn it on to use them, then retry."
    /// The request Fix it sends after the check found a miss (D59).
    static func fixRequest(_ issue: String) -> String {
        "Fix this: " + issue
    }
}
