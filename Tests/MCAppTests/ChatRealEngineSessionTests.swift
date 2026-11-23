import Foundation
import MCCatalog
import MCEngine
import MCLibrary
import Testing

@testable import MCApp

/// A real-engine Chat session (layer 9): `AppModel` + `ChatModel` against the pinned `mlx-serve` and real models,
/// with no UI. Skipped unless `ChatSessionEnvironment.current` resolves — a bare `swift test` never starts it. Each
/// step appends an entry to the record written to `MLXC_CHAT_OUT`.
@MainActor
@Suite(.serialized, .enabled(if: ChatSessionEnvironment.current != nil))
struct ChatRealEngineSessionTests {
    /// What one send left behind: the record entry plus the pieces later steps and assertions need.
    private struct Turn {
        var record: SessionStepRecord
        var result: ChatMessageRecord?
        var job: Job?
        var images: [LibraryImage]
        var referent: UUID?
    }

    @Test func aRealEngineChatSession() async throws {
        let env = try #require(ChatSessionEnvironment.current)
        let root = FileManager.default.temporaryDirectory.appending(
            path: "chat-session-\(UUID().uuidString)", directoryHint: .isDirectory)
        let imagesOut = env.imagesDirectory
        try FileManager.default.createDirectory(at: imagesOut, withIntermediateDirectories: true)
        var record = SessionRecord(steps: [], error: nil)
        // The session is built before `run` so a step failure still leaves it here for shutdown: a throw inside
        // `run` must never leak the engine.
        var session: ChatSession?
        do {
            session = try await prepare(env: env, root: root)
            session = try await run(session: session!, env: env, imagesOut: imagesOut, record: &record)
        } catch {
            record.error = String(describing: error)
        }
        // Cleanup in every path: stop the engine, copy nothing more, remove the root, then the record.
        if let session {
            await session.model.shutdown()
            let escaped = escapedEnginePIDs(root: root)
            #expect(escaped.isEmpty, "mlx-serve outlived the session: \(escaped)")
        }
        write(record, to: env.outURL)
        if record.error != nil {
            throw SessionError.stepFailed(record.error!)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private enum SessionError: Error {
        case stepFailed(String)
    }

    /// Build the session and prove readiness before any step. Kept out of `run` so the test always holds the
    /// session for shutdown.
    private func prepare(env: ChatSessionEnvironment, root: URL) async throws -> ChatSession {
        let defaults = UserDefaults(suiteName: "chat-session-\(UUID().uuidString)")!
        defaults.set(env.agentID, forKey: "MLXCAgentModelID")
        defaults.set(MainWindowMode.chat.rawValue, forKey: AppModel.windowModeDefaultsKey)
        defaults.set(false, forKey: AppModel.civitaiIncludeNSFWKey)
        let session = try await ChatSession.make(env: env, root: root, defaults: defaults)
        await session.waitForReady()
        #expect(
            session.model.agent?.engineModelID != nil, "the agent id did not resolve on the real engine")
        #expect(
            session.model.models.contains(where: ModelSelection.isSelectable),
            "no selectable image model on the real engine")
        return session
    }

    // MARK: - The steps

    /// Returns the live session (a step-8 relaunch replaces it). A throw shuts down whichever session is live at
    /// that moment, so no failure path leaves an engine behind.
    private func run(
        session: ChatSession, env: ChatSessionEnvironment, imagesOut: URL, record: inout SessionRecord
    ) async throws -> ChatSession {
        var session = session
        do {
            return try await runSteps(session: &session, env: env, imagesOut: imagesOut, record: &record)
        } catch {
            await session.model.shutdown()
            throw error
        }
    }

    private func runSteps(
        session: inout ChatSession, env: ChatSessionEnvironment, imagesOut: URL, record: inout SessionRecord
    ) async throws -> ChatSession {
        var stepOneImage: LibraryImage?
        var stepOneJob: Job?
        if env.runs(1) {
            let turn = try await drive(session, step: 1, text: "a lighthouse on a cliff at sunset", imagesOut: imagesOut)
            record.steps.append(turn.record)
            stepOneJob = turn.job
            stepOneImage = turn.images.first
            let job = try #require(turn.job, "step 1 queued no job")
            let image = try #require(turn.images.first, "step 1 saved no image")
            #expect(turn.result != nil)
            #expect(job.status == .done)
            #expect(turn.images.count == 1)
            let file = session.model.fileURL(for: image)
            let png = try Data(contentsOf: file)
            let mlxChunk = try MetadataCodec.read(fromPNG: png)
            let settings = try #require(mlxChunk, "no mlx-create chunk")
            #expect(settings.prompt == job.request.prompt)
            #expect(settings.originalPrompt == nil)
            let chunks = try PNGChunks.parse(png)
            let keyword = Data("parameters\0".utf8)
            let parameters = chunks.first { $0.type == "tEXt" && $0.data.starts(with: keyword) }
            #expect(parameters != nil, "no A1111 parameters chunk")
            if let parameters {
                let text = String(decoding: parameters.data.dropFirst(keyword.count), as: UTF8.self)
                let parsed = A1111Parameters.parse(text)
                #expect(parsed?.prompt == job.request.prompt)
                let userTextVerbatim = text.contains("a lighthouse on a cliff at sunset")
                record.steps[0].notes.append("a1111ContainsUserTextVerbatim=\(userTextVerbatim)")
            }
            let payloadContains = String(decoding: png, as: UTF8.self)
                .contains("a lighthouse on a cliff at sunset")
            record.steps[0].notes.append("pngTextContainsUserTextVerbatim=\(payloadContains)")
            record.steps[0].notes.append("jobPromptContainsUserText=\(job.request.prompt.contains("a lighthouse on a cliff at sunset"))")
        }

        if env.runs(2) {
            if let image = stepOneImage {
                session.chat.largeImageID = image.id
            }
            let turn = try await drive(session, step: 2, text: "make it night", imagesOut: imagesOut)
            record.steps.append(turn.record)
            let job = try #require(turn.job, "step 2 queued no job")
            #expect(job.status == .done)
            #expect(turn.images.count == 1)
            record.steps[record.steps.count - 1].notes.append(
                "sameModel=\(job.request.modelID == stepOneJob?.request.modelID)")
            record.steps[record.steps.count - 1].notes.append(
                "referentWasStepOneImage=\(turn.referent != nil && turn.referent == stepOneImage?.id)")
            record.steps[record.steps.count - 1].notes.append(
                "promptContainsNight=\(job.request.prompt.lowercased().contains("night"))")
            session.chat.largeImageID = nil
        }

        if env.runs(3) {
            let turn = try await drive(
                session, step: 3, text: "give me three different options for a red vintage car on a coastal road",
                imagesOut: imagesOut)
            record.steps.append(turn.record)
            let job = try #require(turn.job, "step 3 queued no job")
            #expect(job.status == .done)
            #expect(turn.record.missText == nil, "a .miss followed a multi-image job")
            if job.batchCount > 1 {
                #expect(
                    !turn.record.phasesSeen.contains("checking"),
                    "the after-image check ran for a multi-image job")
            }
        }

        if env.runs(4) {
            let turn = try await drive(
                session, step: 4, text: "a shop poster that says OPEN LATE in big letters", imagesOut: imagesOut)
            record.steps.append(turn.record)
            if let job = turn.job {
                record.steps[record.steps.count - 1].notes.append(
                    "promptMentionsCar=\(job.request.prompt.lowercased().contains("car"))")
            }
        }

        if env.runs(5) {
            let turn = try await drive(
                session, step: 5, text: "a naked adult woman lying on a bed, explicit, realistic photo",
                imagesOut: imagesOut)
            record.steps.append(turn.record)
            let requestsBefore = await session.civitaiAPI.requests.count
            #expect(requestsBefore == 0, "a Civitai request was made")
            let catalog = try Catalog.decodeValidated(BundledCatalog.fromBundle().bytes)
            let nsfwSHAs = Set(catalog.loraShelf.filter(\.nsfw).map(\.sha256))
            if let job = turn.job {
                let carriedNSFW = (job.request.loras ?? []).contains { nsfwSHAs.contains($0.sha256) }
                #expect(!carriedNSFW, "the job carries an nsfw shelf LoRA while the opt-in is off")
            }
            // An unresolved notice: opt in, retry, and measure what comes back — never accepting a download.
            if let notice = session.chat.messages.last(where: {
                if case .adultNotice(let n) = $0.body { return !n.resolved }
                return false
            }) {
                await session.chat.turnOnAdultContent(messageID: notice.id)
                #expect(session.model.civitai.includeNSFW == true)
                #expect(await session.civitaiAPI.requests.count == 0, "the opt-in made a Civitai request")
                let live = session
                let retry = try await drive(
                    live, step: 5, text: "(retryAdult of the same request)", imagesOut: imagesOut,
                    send: { await live.chat.retryAdult(messageID: notice.id) })
                record.steps.append(retry.record)
                if let card = session.chat.messages.last(where: {
                    if case .download = $0.body { return true }
                    return false
                }) {
                    record.steps[record.steps.count - 1].notes.append("downloadCardAppeared=true")
                    var pendingRequest = false
                    if case .download(let body) = card.body {
                        record.steps[record.steps.count - 1].notes.append("cardText=\(body.text)")
                        let lower = body.text.lowercased()
                        record.steps[record.steps.count - 1].notes.append(
                            "cardTextMentionsLoRA=\(lower.contains("lora") || lower.contains("add-on"))")
                        pendingRequest =
                            body.pendingRequest?.trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty == false
                    }
                    let messagesBefore = session.chat.messages.count
                    await session.chat.dismissDownload(messageID: card.id)
                    record.steps[record.steps.count - 1].notes.append("dismissed download card id=\(card.id)")
                    if pendingRequest {
                        // Dismiss re-sends the card's pending request; `.userText` lands inside the turn, so wait
                        // for the turn to start before waiting for idle — the dismissal's job must not bleed into
                        // the next step's window.
                        try? await eventually(timeout: .seconds(60)) {
                            session.chat.messages.count > messagesBefore || session.chat.phase != .idle
                        }
                        try? await eventually(timeout: .seconds(300)) { session.chat.phase == .idle }
                        #expect(
                            session.chat.phase == .idle,
                            "the dismissed card's follow-up turn did not end")
                        if let job = try? await session.store.jobs(status: .done).last {
                            let loras = (job.request.loras ?? []).map { "\($0.name)@\($0.weight)" }
                            record.steps[record.steps.count - 1].notes.append(
                                "dismissedCardJob=\(job.status.rawValue) loras=\(loras)")
                        }
                    }
                } else {
                    record.steps[record.steps.count - 1].notes.append("downloadCardAppeared=false")
                }
            }
            session.model.civitai.storeIncludeNSFW(false)
        }

        if env.runs(6) {
            let turn = try await drive(
                session, step: 6, text: "un gato naranja durmiendo en un sofá, estilo acuarela",
                imagesOut: imagesOut)
            record.steps.append(turn.record)
            if case .result(let result) = turn.result?.body {
                let reply = result.text.lowercased()
                let looksSpanish = [" un ", " una ", "gato", "sofá"].contains { reply.contains($0) }
                record.steps[record.steps.count - 1].notes.append("replyLooksSpanish=\(looksSpanish)")
            }
        }

        if env.runs(7) {
            // Stop while thinking.
            let before = Set(session.chat.messages.map(\.id))
            await session.chat.send(text: "a castle on a hill")
            try? await eventually(timeout: .seconds(60)) { session.chat.phase == .thinking }
            #expect(session.chat.phase == .thinking)
            await session.chat.stop()
            try? await eventually(timeout: .seconds(30)) { session.chat.phase == .idle }
            #expect(session.chat.phase == .idle, "the turn did not stop within 30 s")
            let newMessages = session.newMessages(since: before)
            #expect(
                newMessages.last?.kind == "userText",
                "a stopped thinking turn left more than the user's message")
            record.steps.append(
                makeRecord(
                    session, step: 7, text: "a castle on a hill", started: Date(), since: before,
                    firstStream: nil, phasesSeen: [], statusesSeen: [], calibratingSeen: false,
                    calibratingSeenInPhase: [], secondsQueuedBeforeFirstRenderStep: nil))

            // Stop while rendering.
            let before2 = Set(session.chat.messages.map(\.id))
            await session.chat.send(text: "a castle on a hill at dawn")
            var stepSeen = false
            try? await eventually(timeout: .seconds(300)) {
                if case .rendering(let step, _, _, _) = session.chat.status { stepSeen = step != nil }
                return stepSeen
            }
            #expect(stepSeen, "no rendering step was reported to stop during")
            await session.chat.stop()
            try? await eventually(timeout: .seconds(60)) { session.chat.phase == .idle }
            #expect(session.chat.phase == .idle, "the rendering job did not stop within 60 s")
            let result = session.resultMessage(since: before2)
            if let result {
                #expect(session.chat.resultState(for: result) == .stopped)
            } else {
                Issue.record("the stopped rendering turn left no .result message")
            }
            if let jobID = result?.jobID, let job = try? await session.store.job(id: jobID) {
                #expect(job.status == .cancelled)
            }
            record.steps.append(
                makeRecord(
                    session, step: 7, text: "a castle on a hill at dawn", started: Date(), since: before2,
                    firstStream: nil, phasesSeen: [], statusesSeen: [], calibratingSeen: false,
                    calibratingSeenInPhase: [], secondsQueuedBeforeFirstRenderStep: nil))
        }

        if env.runs(8) {
            let snapshot = session.chat.messages.map { "\($0.id):\($0.body.kind)" }
            let countBefore = try await imageCount(session)
            await session.model.shutdown()
            let second = try await session.relaunched()
            session = second
            try? await eventually(timeout: .seconds(30)) { session.chat.phase == .idle }
            let after = session.chat.messages.map { "\($0.id):\($0.body.kind)" }
            #expect(after == snapshot, "the conversation did not survive the relaunch")
            await session.chat.clearConversation()
            #expect(session.chat.messages.isEmpty)
            #expect(try await imageCount(session) == countBefore, "the collection's images changed")
            record.steps.append(
                SessionStepRecord(
                    step: 8, userText: "(shutdown, relaunch, clearConversation)", seconds: 0,
                    secondsToFirstStreamedText: nil, messages: [], job: nil, missText: nil,
                    engineLoadedAfter: await session.engineLoaded(), phasesSeen: [],
                    statusesSeen: [], calibratingSeen: false, calibratingSeenInPhase: [],
                    secondsQueuedBeforeFirstRenderStep: nil,
                    notes: ["snapshotMessages=\(snapshot.count)"]))
        }

        if env.runs(9) {
            guard let setupDirectory = env.setupDirectory else {
                Issue.record("step 9 was requested without MLXC_CHAT_SETUP_DIR")
                return session
            }
            // First launch (D60): a second throwaway session whose Weights hold only the agent model —
            // the setup card offers the recommended image model, Accept runs the real download, the
            // engine lists it, and the request parked on the card runs.
            let setup = try await ChatSession.makeSetup(
                env: env, setupDirectory: setupDirectory,
                root: session.root.appending(path: "setup", directoryHint: .isDirectory),
                defaults: session.defaults)
            do {
                try await runSetupStep(setup, env: env, imagesOut: imagesOut, record: &record)
            } catch {
                await setup.model.shutdown()
                throw error
            }
            await setup.model.shutdown()
            // The engine can take a beat past `shutdown` to exit; the suite's escaped-engine check
            // scans this shared root, so absorb the tail here instead of racing the end of the test.
            try? await eventually(timeout: .seconds(60)) {
                escapedEnginePIDs(root: session.root).isEmpty
            }
        }
        return session
    }

    // MARK: - Driving

    /// Sends `text` (or the custom `send`), waits for the phase to come back to idle — past the check — and builds
    /// the step's record entry. Phases are watched the whole time so a `.checking` that never happened is provable.
    private func drive(
        _ session: ChatSession, step: Int, text: String, imagesOut: URL,
        send: (() async -> Void)? = nil
    ) async throws -> Turn {
        let before = Set(session.chat.messages.map(\.id))
        let largeAtSend = session.chat.largeImageID
        let started = Date()
        let phasesSeen = LockedPhases()
        let statusesSeen = LockedPhases()
        let calibratingPhases = LockedPhases()
        let firstStream = LockedDate()
        let referentSeen = LockedUUID()
        let calibratingSeen = LockedBool()
        let queuedAt = LockedDate()
        let firstRenderStepAt = LockedDate()
        let observer = Task { @MainActor in
            var last: ChatPhase?
            while !Task.isCancelled {
                let phase = session.chat.phase
                if session.model.isCalibrating {
                    if phase == .thinking { calibratingSeen.set(true) }
                    let name = ChatSession.phaseName(phase)
                    if !calibratingPhases.values.contains(name) { calibratingPhases.append(name) }
                }
                if phase != last {
                    phasesSeen.append(ChatSession.phaseName(phase))
                    last = phase
                }
                if case .generating = phase, queuedAt.value == nil {
                    queuedAt.set(Date())
                }
                if let status = session.chat.status {
                    let name = ChatSession.statusName(status)
                    if !statusesSeen.values.contains(name) { statusesSeen.append(name) }
                    if case .waitingInQueue = status, queuedAt.value == nil {
                        queuedAt.set(Date())
                    }
                    if case .rendering(let step, _, _, _) = status, step != nil,
                        firstRenderStepAt.value == nil
                    {
                        firstRenderStepAt.set(Date())
                    }
                }
                if firstStream.value == nil, let s = session.chat.streamingText, !s.isEmpty {
                    firstStream.set(Date())
                }
                if referentSeen.value == nil, let id = session.chat.turnReferentImageID {
                    referentSeen.set(id)
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        if let send {
            await send()
        } else {
            await session.chat.send(text: text)
        }
        // `send` returns before `runTurn`'s first hop: the phase is still idle here. Wait for the turn to start
        // first, so waiting for idle cannot see the gap before it as the end of it.
        try? await eventually(timeout: .seconds(60)) { session.chat.phase != .idle }
        try? await eventually(timeout: .seconds(300)) { session.chat.phase == .idle }
        // Give the observer one beat to notice the final transition.
        try? await Task.sleep(for: .milliseconds(60))
        observer.cancel()
        _ = await observer.value
        var record = makeRecord(
            session, step: step, text: text, started: started, since: before,
            firstStream: firstStream.value, phasesSeen: phasesSeen.values,
            statusesSeen: statusesSeen.values, calibratingSeen: calibratingSeen.value,
            calibratingSeenInPhase: calibratingPhases.values,
            secondsQueuedBeforeFirstRenderStep: firstRenderStepAt.value.map {
                $0.timeIntervalSince(queuedAt.value ?? started)
            })
        record.engineLoadedAfter = await session.engineLoaded()
        let effectiveReferent = referentSeen.value ?? largeAtSend
        record.notes.append("referent=\(effectiveReferent?.uuidString ?? "none")")
        let result = session.resultMessage(since: before)
        var job: Job?
        var images: [LibraryImage] = []
        if let jobID = result?.jobID, let found = try? await session.store.job(id: jobID) {
            job = found
            images = (try? await session.store.images(jobID: jobID)) ?? []
            record.job = SessionStepRecord.SessionJob(
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
                resultState: result.map { ChatSession.resultStateName(session.chat.resultState(for: $0)) } ?? nil)
            if let first = images.first {
                let destination = imagesOut.appending(path: "step\(step).png")
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: session.model.fileURL(for: first), to: destination)
            }
        }
        return Turn(record: record, result: result, job: job, images: images, referent: effectiveReferent)
    }

    private func makeRecord(
        _ session: ChatSession, step: Int, text: String, started: Date, since: Set<Int64>,
        firstStream: Date?, phasesSeen: [String], statusesSeen: [String], calibratingSeen: Bool,
        calibratingSeenInPhase: [String], secondsQueuedBeforeFirstRenderStep: Double?
    ) -> SessionStepRecord {
        SessionStepRecord(
            step: step,
            userText: text,
            seconds: Date().timeIntervalSince(started),
            secondsToFirstStreamedText: firstStream.map { $0.timeIntervalSince(started) },
            messages: session.newMessages(since: since),
            job: nil,
            missText: session.missMessage(since: since)?.text,
            engineLoadedAfter: [],
            phasesSeen: phasesSeen,
            statusesSeen: statusesSeen,
            calibratingSeen: calibratingSeen,
            calibratingSeenInPhase: calibratingSeenInPhase,
            secondsQueuedBeforeFirstRenderStep: secondsQueuedBeforeFirstRenderStep,
            notes: [])
    }

    // MARK: - Small helpers

    private func imageCount(_ session: ChatSession) async throws -> Int {
        try await session.store.collections().first(where: { $0.id == session.model.currentCollection.id })?
            .imageCount ?? 0
    }

    /// `pgrep -f <root>`: pids whose argv carries the throwaway root — how an escaped engine is caught without ever
    /// matching the process name (the user's own MLX-Serve app must not be touched).
    private func escapedEnginePIDs(root: URL) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap {
            Int32($0)
        }
    }

    private func write(_ record: SessionRecord, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: url)
        } catch {
            Issue.record("the session record could not be written: \(error)")
        }
    }
}

/// Phase names collected by the turn observer without a data race (the observer and the test both run on the main
/// actor, but the observer mutates across an `await`).
private final class LockedPhases: @unchecked Sendable {
    private(set) var values: [String] = []
    func append(_ name: String) { values.append(name) }
}

/// The first time streaming text appeared, for `secondsToFirstStreamedText`.
private final class LockedDate: @unchecked Sendable {
    private(set) var value: Date?
    func set(_ date: Date) { value = date }
}

/// The image id the turn used as its referent, seen by the observer while the turn ran.
private final class LockedUUID: @unchecked Sendable {
    private(set) var value: UUID?
    func set(_ id: UUID) { value = id }
}

/// Whether `isCalibrating` was true while the turn was thinking.
private final class LockedBool: @unchecked Sendable {
    private(set) var value = false
    func set(_ new: Bool) { value = new }
}
