import Foundation
import MCCatalog
import MCEngine
import MCEnhancer
import MCGeneration
import MCLibrary

/// What `startEnhance()` did with a press (U7). A started run reports through `enhanceState`.
public enum EnhanceStart: Equatable, Sendable {
    /// The run has begun. It waits for the image in progress, if any, then streams ahead of queued jobs (KTD5).
    case started
    /// No enhancer is installed. U8 opens the install sheet. Nothing is sent to the engine.
    case notInstalled
    /// The press cannot start now. `reason` is plain language for the card.
    case unavailable(reason: String)
}

/// The Enhance card the prompt editor shows (KTD10, R3). `stale` is derived from the current prompt, so editing it
/// marks a run or result stale without any bookkeeping on the edit.
public enum EnhanceState: Equatable, Sendable {
    case idle
    /// The queue is running an image. The enhancement starts after it.
    case waiting(stale: Bool)
    /// The text so far.
    case streaming(text: String, stale: Bool)
    /// A finished result. Accept is refused while it is stale.
    case ready(EnhancedPrompt, stale: Bool)
    case failed(message: String)
}

/// One Enhance run: the request built on the prompt at press time, and where the run is now.
struct EnhanceRun: Sendable {
    let id: UUID
    let builtOn: String
    let request: EnhancementRequest
    var phase: EnhancePhase
}

enum EnhancePhase: Equatable, Sendable {
    case waiting
    case streaming(String)
    case ready(EnhancedPrompt)
    case failed(String)
}

extension AppModel {
    static let emptyPromptReason = "Write a prompt before you enhance it."
    static let alreadyRunningReason = "An enhancement is already running. Cancel it or wait for it to finish."
    static let noModelReason = "Choose a model before you enhance a prompt."
    static let noResultReason = "The prompt enhancer returned no prompt. Your prompt is unchanged. Try again."

    /// Whether an Enhance is waiting for the image or streaming now. A second press is refused meanwhile.
    var enhanceIsRunning: Bool {
        guard let phase = enhanceRun?.phase else { return false }
        switch phase {
        case .waiting, .streaming: return true
        case .ready, .failed: return false
        }
    }

    /// The Enhance card, or `.idle` when none is up.
    public var enhanceState: EnhanceState {
        guard let run = enhanceRun else { return .idle }
        let stale = run.builtOn != prompt
        switch run.phase {
        case .waiting: return .waiting(stale: stale)
        case .streaming(let text): return .streaming(text: text, stale: stale)
        case .ready(let result): return .ready(result, stale: stale)
        case .failed(let message): return .failed(message: message)
        }
    }

    /// Whether any job is queued. U8 says the next image starts after an Enhance when one is.
    public var hasQueuedJobs: Bool { queueJobs.contains { $0.status == .queued } }

    /// Whether an image job is running now. A waiting Enhance then starts after it; otherwise it is loading the enhancer.
    public var enhanceWaitsForImage: Bool { queueJobs.contains { $0.status == .running } }

    /// Below 24 GiB the enhancer's lease unloads the resident image model and re-warms it when the queue is empty, so
    /// U8 shows a one-time note (R14). Larger tiers keep both resident.
    public var enhanceWillReloadImageModel: Bool { memoryTier.maxResidentModels == 1 }

    /// Drops the provenance when the prompt is emptied or no longer derives from the accepted enhancement: the prompt
    /// and the accepted text share no word of four or more letters or digits.
    func promptDidChange() {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            originalPrompt = nil
            acceptedEnhancedPrompt = nil
        } else if originalPrompt != nil, let accepted = acceptedEnhancedPrompt,
            Self.significantWords(prompt).isDisjoint(with: Self.significantWords(accepted))
        {
            originalPrompt = nil
            acceptedEnhancedPrompt = nil
        }
    }

    /// Lowercased words of four or more letters or digits: the content words two prompts must share to be related.
    static func significantWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 4 })
    }

    /// Starts an Enhance on the current prompt (R1, R2, R4). Regenerate is this same call once a card is up: it
    /// replaces the card. Validation runs first; the LoRA lookup awaits the store. The run then waits for the image in
    /// progress and streams ahead of queued jobs (KTD5).
    public func startEnhance() async -> EnhanceStart {
        guard !enhanceIsRunning else { return .unavailable(reason: Self.alreadyRunningReason) }
        let builtOn = prompt
        guard !builtOn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(reason: Self.emptyPromptReason)
        }
        guard let enhancer, enhancer.isInstalled, let enhancerModelID = enhancer.engineModelID else {
            return .notInstalled
        }
        guard let model = selectedModel, ModelSelection.isSelectable(model), let family = model.family else {
            return .unavailable(reason: Self.noModelReason)
        }
        let loras: [EnhancementLoRA]
        do {
            loras = try await enhancementLoRAs()
        } catch {
            return .unavailable(reason: message(for: error))
        }
        // The LoRA lookup awaited the store, so another press may have started a run meanwhile.
        guard !enhanceIsRunning else { return .unavailable(reason: Self.alreadyRunningReason) }
        switch PromptEnhancer.request(
            prompt: builtOn, family: family, negativePrompt: negativePrompt,
            loras: loras, enhancerModelID: enhancerModelID)
        {
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        case .ready(let request):
            let run = EnhanceRun(id: UUID(), builtOn: builtOn, request: request, phase: .waiting)
            enhanceRun = run
            enhanceTask = Task { await self.runEnhance(run.id, request: request, enhancerModelID: enhancerModelID) }
            return .started
        }
    }

    /// Cancels a waiting or streaming run and drops its card (R3). The prompt keeps the user's text.
    public func cancelEnhance() {
        guard enhanceIsRunning else { return }
        enhanceTask?.cancel()
        enhanceRun = nil
    }

    /// Discards a finished result (R3). Neither the prompt nor the original-prompt provenance changes (KTD7).
    public func revertEnhance() {
        guard !enhanceIsRunning else { return }
        enhanceRun = nil
    }

    /// Replaces the prompt with a ready result and records the text it replaced as the original prompt (KTD7, R17).
    /// Refused while the result is stale. The negative prompt changes only when the request expected one (R5).
    public func acceptEnhance() {
        guard case .ready(let result, stale: false) = enhanceState else { return }
        let replaced = prompt
        // The provenance is set after the prompt: assigning the prompt runs the cleanup, which would otherwise clear a
        // result that shares no four-letter word with the previous accepted text, and leave the original half set.
        prompt = result.prompt
        acceptedEnhancedPrompt = result.prompt
        originalPrompt = replaced
        if let negative = result.negativePrompt { negativePrompt = negative }
        enhanceRun = nil
    }

    /// Puts the text an accepted enhancement replaced back into the prompt, and drops the provenance.
    public func restoreOriginalPrompt() {
        guard let original = originalPrompt else { return }
        originalPrompt = nil
        acceptedEnhancedPrompt = nil
        prompt = original
    }

    /// Streams the run's request inside the executor's lease, then cleans the reply. Only the run still current writes
    /// state, so a cancelled or replaced run leaves nothing behind.
    private func runEnhance(_ id: UUID, request: EnhancementRequest, enhancerModelID: String) async {
        let client = self.client
        do {
            let reply = try await executor.withEnhancerLease(enhancerModelID: enhancerModelID) {
                await self.setEnhancePhase(id, .streaming(""))
                var text = ""
                for try await delta in client.streamChat(request.chat) {
                    text += delta
                    await self.setEnhancePhase(id, .streaming(text))
                }
                // A cancelled stream ends early without throwing, so it is checked before the reply leaves the lease.
                try Task.checkCancellation()
                return text
            }
            guard
                let enhanced = EnhancementCleaner.clean(
                    reply, triggerWords: request.triggerWords, expectsNegativePrompt: request.expectsNegativePrompt)
            else {
                setEnhancePhase(id, .failed(Self.noResultReason))
                return
            }
            setEnhancePhase(id, .ready(enhanced))
        } catch is CancellationError {
            return
        } catch {
            setEnhancePhase(id, .failed(message(for: error)))
        }
    }

    /// Sets the phase of run `id` when it is still the current run. A cancelled or replaced run writes nothing.
    private func setEnhancePhase(_ id: UUID, _ phase: EnhancePhase) {
        guard enhanceRun?.id == id else { return }
        enhanceRun?.phase = phase
    }

    /// The LoRAs the next image would use (enabled, fitting, non-zero weight: the rows a job freezes), each with its
    /// trigger words and creator example prompts (R8, R9). A local import has no source and contributes trigger words only.
    private func enhancementLoRAs() async throws -> [EnhancementLoRA] {
        var contexts: [EnhancementLoRA] = []
        for row in loraStack where row.isUsed {
            let examples = try await store.loraSource(loraID: row.id)?.examplePrompts ?? []
            contexts.append(EnhancementLoRA(name: row.name, triggerWords: row.triggerWords, examplePrompts: examples))
        }
        return contexts
    }
}
