import Foundation
import MCCatalog
import MCLibrary
import Testing

@testable import MCApp

/// Step 9 of the real-engine Chat session: the first-launch setup path (D60). Kept out of
/// `ChatRealEngineSessionTests` for size — it owns one concept: wait for the offered card, park a
/// request on it, accept it — a real download — then prove the card finished when the engine listed
/// the model and the parked request ran once.
extension ChatRealEngineSessionTests {
    func runSetupStep(
        _ setup: ChatSession, env: ChatSessionEnvironment, imagesOut: URL,
        record: inout SessionRecord
    ) async throws {
        let started = Date()
        let before = Set(setup.chat.messages.map(\.id))
        var notes: [String] = []

        // The offer lands once the first models refresh has read install status; before that the
        // missing-model check runs on unknown state and nothing may appear.
        var cardID: Int64?
        try await eventually(timeout: .seconds(300)) {
            cardID =
                setup.chat.messages.last(where: {
                    if case .download = $0.body { return true }
                    return false
                })?.id
            return cardID != nil
        }
        let id = try #require(cardID, "the setup card was never offered")
        let body = setup.chat.messages.first { $0.id == id }.flatMap {
            if case .download(let body) = $0.body { return body }
            return nil
        }
        let offered = try #require(body, "the setup card is not a download")
        #expect(offered.isSetup, "the first-launch card is not marked as setup")
        #expect(offered.state == .offered)
        let offeredModel = try #require(
            offered.items.first(where: { $0.kind == .model }), "the setup card offered no model")
        notes.append("offered=\(offeredModel.id)")
        if let expected = env.setupModelID {
            #expect(offeredModel.id == expected, "setup offered \(offeredModel.id), not \(expected)")
        }

        // A request sent while the card stands parks on it instead of starting a turn.
        let text = "a lighthouse on a cliff at sunset"
        await setup.chat.send(text: text)
        await setup.chat.turnTask?.value
        let parked = setup.chat.messages.first { $0.id == id }.flatMap {
            if case .download(let body) = $0.body { return body.pendingRequest }
            return nil
        }
        #expect(parked == text, "the request did not park on the setup card")

        // Accept runs the real install; the card reaches a terminal state when the engine lists the
        // model (or the install genuinely failed).
        let accept = Task { await setup.chat.acceptDownload(messageID: id) }
        try await eventually(timeout: .seconds(3600)) {
            guard case .download(let card) = setup.chat.messages.first(where: { $0.id == id })?.body
            else { return false }
            if case .failed = card.state { return true }
            return card.state == .finished
        }
        await accept.value
        let terminal = setup.chat.messages.first { $0.id == id }.flatMap {
            if case .download(let body) = $0.body { return body }
            return nil
        }
        #expect(terminal?.state == .finished, "the setup card did not finish: \(String(describing: terminal?.state))")
        notes.append("cardFinishedAfter=\(Date().timeIntervalSince(started))")

        // The parked request resumes as the next turn — its `.userText` was already recorded, so the
        // conversation must still hold exactly one, and the card's slot is consumed as the replay
        // begins (asynchronously to `acceptDownload` returning).
        try? await eventually(timeout: .seconds(60)) { setup.chat.phase != .idle }
        try await eventually(timeout: .seconds(600)) { setup.chat.phase == .idle }
        try await eventually(timeout: .seconds(60)) {
            setup.chat.messages.first { $0.id == id }.flatMap {
                if case .download(let body) = $0.body { return body.pendingRequest == nil }
                return nil
            } == true
        }
        let userTexts = setup.chat.messages.filter { $0.body.kind == "userText" }
        #expect(userTexts.count == 1, "the parked request was recorded \(userTexts.count) times")

        let result = setup.resultMessage(since: before)
        var job: Job?
        var images: [LibraryImage] = []
        var jobRecord: SessionStepRecord.SessionJob?
        if let jobID = result?.jobID, let found = try? await setup.store.job(id: jobID) {
            job = found
            images = (try? await setup.store.images(jobID: jobID)) ?? []
            jobRecord = SessionStepRecord.SessionJob(
                jobID: jobID.uuidString,
                modelID: found.request.modelID,
                prompt: found.request.prompt,
                width: found.request.width,
                height: found.request.height,
                batchCount: found.batchCount,
                seedPolicy: found.seedPolicy,
                loras: (found.request.loras ?? []).map { "\($0.name)@\($0.weight)" },
                status: found.status.rawValue,
                failure: found.failure?.message,
                savedImageCount: images.count,
                images: images.map { .init(width: $0.width, height: $0.height, seed: $0.seed) },
                resultState: result.map { ChatSession.resultStateName(setup.chat.resultState(for: $0)) } ?? nil)
        }
        #expect(job?.status == .done, "the resumed request's job did not complete")
        #expect(!images.isEmpty, "the resumed request saved no image")
        if let first = images.first {
            let destination = imagesOut.appending(path: "step9.png")
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: setup.model.fileURL(for: first), to: destination)
        }
        if let job {
            notes.append("jobModel=\(job.request.modelID)")
            // The card item id is the catalog id; the job's model id is the engine's `org/name`.
            let catalog = try? Catalog.decodeValidated(BundledCatalog.fromBundle().bytes)
            let offeredRepo = catalog?.models.first(where: { $0.id == offeredModel.id })?.repo
            notes.append("jobUsedOfferedModel=\(offeredRepo == nil || job.request.modelID == offeredRepo)")
        }
        notes.append("engineListed=\(await setup.engineLoaded().joined(separator: ","))")

        record.steps.append(
            SessionStepRecord(
                step: 9, userText: text, seconds: Date().timeIntervalSince(started),
                secondsToFirstStreamedText: nil, messages: setup.newMessages(since: before),
                job: jobRecord, missText: setup.missMessage(since: before)?.text,
                engineLoadedAfter: await setup.engineLoaded(), phasesSeen: [],
                statusesSeen: [], calibratingSeen: false, calibratingSeenInPhase: [],
                secondsQueuedBeforeFirstRenderStep: nil, notes: notes))
    }
}
