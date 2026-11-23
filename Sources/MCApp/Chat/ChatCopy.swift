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
    /// The first line of a fresh install's conversation (D60).
    static let greeting = "Hi. Tell me what picture you want and I'll make it."
    /// The setup card's sentence (R26): it names what is missing, in the user's words.
    static func setupOffer(needsImageModel: Bool, needsAgentModel: Bool) -> String {
        if needsImageModel && needsAgentModel {
            return "First I need two downloads: an image model and my own model. They stay on this Mac."
        }
        if needsAgentModel {
            return "I need one download before we start: my own model. It stays on this Mac."
        }
        return "I need one download before we start: an image model. It stays on this Mac."
    }

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
