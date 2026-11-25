import Foundation
import MCCatalog
import MCLibrary
import Testing

@testable import MCApp

/// Step 9 of the real-engine Chat session: the first-launch setup path (D60, amended 2026-11-24). Kept out
/// of `ChatRealEngineSessionTests` for size — it owns one concept: install the agent through the setup
/// screen's action, wait for Chat to become ready, then prove a request with no image model installed
/// gets a non-setup `.download` card whose Accept runs the real download and resumes the parked request.
extension ChatRealEngineSessionTests {
    func runSetupStep(
        _ setup: ChatSession, env: ChatSessionEnvironment, imagesOut: URL,
        record: inout SessionRecord
    ) async throws {
        let started = Date()
        let before = Set(setup.chat.messages.map(\.id))
        var notes: [String] = []

        // Nothing is ready until the agent model is installed and the engine lists it. The setup screen's
        // Download, Resume and Retry are all `installAccepted`: it records the license acceptance (D20)
        // and runs the real catalog download. The session shares the main run's defaults, where the
        // greeting was already posted — clear the flag so this first-launch session greets again.
        setup.defaults.removeObject(forKey: ChatModel.greetingDefaultsKey)
        try await eventually(timeout: .seconds(300)) { setup.model.modelsLoaded }
        #expect(setup.chat.chatReady == false, "chat was ready before the agent install")
        let agentModel = try #require(
            setup.model.browser.catalogModel(ofKind: .agent), "the catalog lists no agent model")
        notes.append("agentModel=\(agentModel.id)")
        if let expected = env.setupModelID {
            #expect(agentModel.id == expected, "setup installs \(agentModel.id), not \(expected)")
        }

        let install = await setup.model.browser.installAccepted(agentModel.id)
        try #require(install != nil, "the agent install did not start")
        await install?.value
        try await eventually(timeout: .seconds(300)) { setup.chat.chatReady }
        notes.append("agentInstalledAfter=\(Date().timeIntervalSince(started))")

        // Chat ready on an empty conversation posts the greeting once (D60).
        try await eventually(timeout: .seconds(30)) {
            setup.chat.messages.contains {
                if case .agentText(let text) = $0.body { return text == ChatCopy.greeting }
                return false
            }
        }

        // With no image model installed the agent sees only the catalog's download offers, so the
        // lighthouse request resolves to a `.download` card proposing one — never a setup card (D60).
        let text = "a lighthouse on a cliff at sunset"
        await setup.chat.send(text: text)
        await setup.chat.turnTask?.value
        var cardID: Int64?
        try await eventually(timeout: .seconds(600)) {
            cardID =
                setup.chat.messages.last(where: {
                    guard case .download(let card) = $0.body else { return false }
                    return !card.isSetup
                })?.id
            return cardID != nil
        }
        let id = try #require(cardID, "no download card was offered")
        let body = setup.chat.messages.first { $0.id == id }.flatMap {
            if case .download(let body) = $0.body { return body }
            return nil
        }
        let offered = try #require(body, "the download card is not a download")
        #expect(offered.state == .offered)
        #expect(offered.pendingRequest == text, "the request did not park on the card")
        let offeredModel = try #require(
            offered.items.first(where: { $0.kind == .model }), "the card offered no model")
        notes.append("offered=\(offeredModel.id)")

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
        #expect(terminal?.state == .finished, "the download card did not finish: \(String(describing: terminal?.state))")
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
