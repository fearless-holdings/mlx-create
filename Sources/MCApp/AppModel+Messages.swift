import Foundation
import MCEngine
import MCGeneration
import MCLibrary

// User-facing text for model ids and errors.
extension AppModel {
    func displayName(for modelID: String) -> String {
        models.first { $0.id == modelID }?.family?.displayName ?? modelID
    }

    /// The text shown for an error: the user-facing copy the layer already wrote, or the framework's description.
    func message(for error: Error) -> String {
        switch error {
        case let crash as EngineCrash: crash.message
        case let engine as EngineError: engine.userMessage
        case GenerationError.emptyPrompt: "Type a prompt before generating."
        case GenerationError.modelUnavailable(let reason): reason
        case GenerationError.invalidBatchCount: "Batch count must be at least 1."
        case JobQueueError.notFailed: "Only failed jobs can be retried."
        case LibraryError.notQueued: "Only queued jobs can be moved."
        case LibraryError.loraUnavailable(let name):
            "\"\(name)\" is missing from the library or its file is gone. Remove it from the stack or re-import it."
        case LoRAStackError.tooMany:
            "A job can use up to \(GenerationComposer.maxLoRAs) LoRAs. Remove one to generate."
        case LibraryError.invalidName: "Enter a name for the collection."
        case LibraryError.duplicateCollectionName: "Another collection already has that name. Choose a different name."
        case LibraryError.defaultCollectionCannotBeDeleted: "The default collection cannot be deleted."
        case LibraryError.collectionHasImages(let count):
            "This collection still holds \(count) image\(count == 1 ? "" : "s"). Move or delete them first."
        case LibraryError.collectionHasJobs(let count):
            "This collection still has \(count) queued, running or paused job\(count == 1 ? "" : "s"). Wait for them to finish or cancel them first."
        case LibraryError.folderReconcileFailed(let path):
            "The library could not move \(path) into the Collections folder. Check that the library folder is writable, then reopen the app."
        case LibraryError.notFound: "That item is no longer in the library."
        default: error.localizedDescription
        }
    }
}
