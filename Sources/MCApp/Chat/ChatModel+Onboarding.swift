import Foundation
import MCLibrary

/// Chat readiness and the greeting (D60, amended 2026-11-24): Chat plans once the engine lists the agent
/// model — image models are no longer required, since the agent sees the catalog's fitting models as
/// download offers and proposes one when a request needs it. A conversation still empty when Chat first
/// becomes ready gets the greeting, once. First-launch setup cards the old build posted stay in the store
/// and keep reconciling, but nothing new is offered here.
extension ChatModel {
    /// The defaults key recording that the greeting was posted: it is a first-launch touch, shown once.
    static let greetingDefaultsKey = "chatGreetingShown"

    /// Chat can plan: the engine lists the agent model. An image model is not required — with none
    /// installed the agent's options are the catalog's download offers, and a plan that names one becomes
    /// a `.download` card whose Accept installs it.
    var chatReady: Bool {
        app.agent?.engineModelID != nil
    }

    /// Posts the greeting when Chat is ready and the conversation is empty (D60). Runs overlap when model
    /// refreshes and conversation loads do: a run already in flight makes a second one set the flag, and
    /// the first runs once more with its writes already in place, so the greeting lands exactly once.
    func offerGreetingIfNeeded() async {
        if greetingRunning {
            greetingAgain = true
            return
        }
        greetingRunning = true
        repeat {
            greetingAgain = false
            await greetingPass()
        } while greetingAgain
        greetingRunning = false
    }

    /// One greeting pass. Until the first models refresh the install status is unknown, so nothing is
    /// posted then. The greeting is a first-launch touch: once posted it is remembered in defaults and never
    /// repeats, so a cleared or switched-to empty conversation stays empty. A ready conversation that already
    /// holds messages marks the key as well — an upgraded user who was chatting before the greeting existed
    /// does not receive it later in the next empty collection.
    private func greetingPass() async {
        guard app.modelsLoaded, chatReady, !app.defaults.bool(forKey: Self.greetingDefaultsKey) else { return }
        guard messages.isEmpty else {
            app.defaults.set(true, forKey: Self.greetingDefaultsKey)
            return
        }
        if await append(.agentText(ChatCopy.greeting), collectionID: app.currentCollection.id) != nil {
            app.defaults.set(true, forKey: Self.greetingDefaultsKey)
        }
    }

    /// Runs after every successful `refreshModels()` (AE7): each card is reconciled against what the engine now
    /// lists, the greeting is posted if Chat just became ready on an empty conversation, and a request a
    /// finished card was holding runs as a new turn.
    func readinessDidChange() async {
        await reconcileCards()
        await offerGreetingIfNeeded()
        await resumeHeldRequests()
    }

    /// Reconciles each shown `.download` card against the current truth (R28, AE7). Runs on a refresh and on every
    /// conversation load, so a card a relaunch left `.accepted` turns retryable instead of stuck. Cards a
    /// pre-amendment build marked `isSetup` reconcile the same way; the view filters them out.
    func reconcileCards() async {
        for record in messages {
            guard case .download(let card) = record.body else { continue }
            await reconcile(record, card: card)
        }
    }
}
