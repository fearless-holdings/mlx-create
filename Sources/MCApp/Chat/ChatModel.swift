import Foundation
import MCGeneration
import MCLibrary

/// What the agent is doing now (docs/lld/agent.md §2).
enum ChatPhase: Equatable, Sendable {
    case idle
    /// The agent model is planning a reply.
    case thinking
    /// A queued job the turn made is being followed.
    case generating(jobID: UUID)
    /// The after-image check is reading the made image (D59). It never blocks a send.
    case checking(jobID: UUID)
}

/// The pending message's status. Views format it; no user-facing string lives here except in ``ChatCopy``.
enum ChatStatus: Equatable, Sendable {
    case thinking
    /// The job is queued behind other work.
    case waitingInQueue
    /// The job is rendering; `image` and `of` are 1-based.
    case rendering(step: Int?, total: Int?, image: Int, of: Int)
    case queuePaused
    /// The check is reading the image (D59).
    case checking
}

/// What a result message shows, read from its job (never stored).
enum ChatResultState: Equatable, Sendable {
    case working
    case done(imageCount: Int)
    case failed(message: String)
    case stopped
}

/// Chat mode's state and actions (docs/lld/agent.md §7): the current collection's conversation, the turn in flight and
/// the job it follows. Planning runs through `MCAgent`, generation through the composer and persistence through the
/// store; nothing infers here.
@MainActor @Observable
final class ChatModel {
    unowned let app: AppModel

    /// The current collection's conversation, oldest first (newest 200). `reloadMessages()` fills it.
    private(set) var messages: [ChatMessageRecord] = []
    /// The text being composed; ``send()`` clears it.
    var input = ""
    private(set) var phase: ChatPhase = .idle
    /// nil while idle.
    private(set) var status: ChatStatus?
    /// The agent's sentence so far while a reply streams (R32); nil otherwise.
    private(set) var streamingText: String?
    /// The image shown large in Chat mode, set by the view. First choice for the referent (D57).
    var largeImageID: UUID?
    /// The task of the turn in flight, kept so a test can await it (as `enhanceTask` is).
    var turnTask: Task<Void, Never>?
    /// The task of the check in flight (D59); a send cancels it.
    var checkTask: Task<Void, Never>?
    /// The cards whose Accept flow is running now, so a reload or refresh can tell a live install from one a
    /// relaunch left behind.
    var activeDownloadMessageIDs: Set<Int64> = []
    /// Mutual exclusion for `offerSetupIfNeeded`: a concurrent run raises the flag and the in-flight run repeats,
    /// so two overlapping model refreshes cannot append the card (and greeting) twice.
    var offerSetupRunning = false
    var offerSetupAgain = false

    /// The collection the running turn writes to, captured when the turn is claimed — `send` or a card's held
    /// request — so a switch mid-turn never misfiles a message and a clear can tell whose work the phase is.
    var turnCollectionID: UUID?
    /// The user text of the running turn; a failed job's error offers it again.
    var turnUserText: String?
    /// A referent the sender pinned (D59's Fix it), first choice ahead of `largeImageID` for that one turn.
    var turnReferentImageID: UUID?
    /// Whether the followed job's turn ran in this session; a relaunched job's finish never starts the check (D59).
    var followedFromCurrentTurn = false
    /// The newest `.progress` step and total the followed job reported.
    var followedProgress: (step: Int, total: Int)?
    /// The job rows and saved-image counts behind `resultState(for:)` and `status`, refreshed on events and reload.
    var resultJobs: [UUID: Job] = [:]
    var resultCounts: [UUID: Int] = [:]

    init(app: AppModel) {
        self.app = app
    }

    /// Whether a turn is planning or generating: Send is a no-op meanwhile. The check does not count (D59), so Send
    /// stays live while it reads the image.
    var isWorking: Bool {
        if case .checking = phase { return false }
        return phase != .idle
    }

    /// Idle with a non-blank `input`.
    var canSend: Bool {
        !isWorking && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends `input` as the user's message and clears it.
    func send() async {
        guard canSend else { return }
        let text = input
        input = ""
        await send(text: text)
    }

    /// Sends `text` as the user's message; suggestion and retry buttons use this. Ignored while a turn runs or when
    /// the text is blank.
    func send(text: String, referentImageID: UUID? = nil) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if case .checking = phase {
            // A send during the check cancels it silently and starts the turn instead (D59).
            checkTask?.cancel()
            endPhase()
        }
        await app.ensureCurrentCollection()
        guard beginTurn() else { return }
        let collectionID = app.currentCollection.id
        turnCollectionID = collectionID
        turnReferentImageID = referentImageID
        turnTask = Task {
            await self.runTurn(text: text, collectionID: collectionID)
            await self.resumeHeldRequests()
        }
    }

    /// Claims the turn synchronously: true while it was idle, marking it thinking so a send racing this one returns
    /// instead of starting a second turn. `runTurn` marks the same state again.
    func beginTurn() -> Bool {
        guard phase == .idle else { return false }
        beginThinking()
        return true
    }

    /// Stops the turn (AE5): a planning reply is cancelled mid-stream and records nothing beyond the user's message;
    /// a generating job is cancelled and the job's own event ends the phase.
    func stop() async {
        switch phase {
        case .thinking:
            turnTask?.cancel()
        case .generating(let jobID):
            try? await app.executor.cancel(jobID)
        case .checking:
            checkTask?.cancel()
        case .idle:
            break
        }
    }

    /// Records the chosen suggestion on its question, then sends it as the user's message.
    func chooseSuggestion(_ suggestion: String, messageID: Int64) async {
        guard let record = messages.first(where: { $0.id == messageID }),
            case .question(let question) = record.body
        else { return }
        let marked = ChatQuestion(text: question.text, suggestions: question.suggestions, chosen: suggestion)
        do {
            try await app.store.updateChatMessage(id: messageID, body: .question(marked))
        } catch {
            app.lastError = app.message(for: error)
        }
        replaceMessage(
            ChatMessageRecord(
                id: record.id, collectionID: record.collectionID, author: record.author,
                body: .question(marked), jobID: record.jobID, createdAt: record.createdAt))
        await send(text: suggestion)
    }

    /// An `.error` message's retry button sends its `retryRequest` again.
    func retry(messageID: Int64) async {
        guard let record = messages.first(where: { $0.id == messageID }),
            case .error(let failure) = record.body, let request = failure.retryRequest
        else { return }
        await send(text: request)
    }

    /// Removes every message of `collectionID` — the collection the confirmation named. A turn or followed job
    /// that belongs to it is stopped first; work still followed from another collection keeps running, because a
    /// mid-render switch leaves it following there and its conversation is not the one cleared. Images and jobs
    /// are untouched.
    func clearConversation(collectionID: UUID) async {
        if await phaseBelongs(to: collectionID) {
            await stop()
            if phase != .thinking { endPhase() }
            followedProgress = nil
        }
        do {
            try await app.store.clearChatMessages(collectionID: collectionID)
        } catch {
            app.lastError = app.message(for: error)
        }
        // The shown messages are this collection's only while it is still current; a switch that landed during
        // the confirmation would have made them another's.
        guard collectionID == app.currentCollection.id else { return }
        loadMessages([])
        resultJobs = [:]
        resultCounts = [:]
    }

    /// Whether the phase's work belongs to `collectionID`: a thinking turn's collection was captured when the turn
    /// was claimed, and a followed or checked job's comes from its row.
    private func phaseBelongs(to collectionID: UUID) async -> Bool {
        switch phase {
        case .idle:
            return false
        case .thinking:
            return turnCollectionID == collectionID
        case .generating(let jobID), .checking(let jobID):
            if let job = resultJobs[jobID] { return job.collectionID == collectionID }
            return (try? await app.store.job(id: jobID))?.collectionID == collectionID
        }
    }

    /// Loads the current collection's conversation (newest 200) and refreshes the result cache, so launch and a
    /// collection switch show what the library holds. An in-flight `.result` job is followed again (KTD18).
    func reloadMessages() async {
        do {
            let records = try await app.store.chatMessages(collectionID: app.currentCollection.id, limit: 200)
            loadMessages(records)
        } catch {
            app.lastError = app.message(for: error)
        }
        await refreshJobCache()
        await resumeFollowing()
        await reconcileCards()
        await offerSetupIfNeeded()
        await resumeHeldRequests()
    }
}

/// The writes the turn, context and jobs files make; `private(set)` keeps them inside this file.
extension ChatModel {
    /// Appends the record to the shown conversation.
    func recordMessage(_ record: ChatMessageRecord) {
        messages.append(record)
    }

    /// Replaces the whole conversation, as a load or a clear does.
    func loadMessages(_ records: [ChatMessageRecord]) {
        messages = records
    }

    /// Replaces one record in place, as a marked `chosen` does.
    func replaceMessage(_ record: ChatMessageRecord) {
        if let index = messages.firstIndex(where: { $0.id == record.id }) { messages[index] = record }
    }

    /// The turn entered its planning phase.
    func beginThinking() {
        phase = .thinking
        status = .thinking
        streamingText = ""
    }

    /// The turn is following `jobID`.
    func beginGenerating(_ jobID: UUID) {
        phase = .generating(jobID: jobID)
        status = .waitingInQueue
    }

    /// The after-image check started on `jobID` (D59).
    func beginChecking(_ jobID: UUID) {
        phase = .checking(jobID: jobID)
        status = .checking
    }

    /// The turn ended: idle, nothing pending. `streamingText` is cleared by the turn's own cleanup.
    func endPhase() {
        phase = .idle
        status = nil
    }

    /// Updates the pending status a job event derived.
    func publishStatus(_ value: ChatStatus?) {
        status = value
    }

    /// Publishes the sentence the agent reply has streamed so far (R32).
    func publishStream(_ text: String?) {
        streamingText = text
    }
}
