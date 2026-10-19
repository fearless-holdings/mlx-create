import Foundation
import MCGeneration

/// How queue jobs read in the queue strip and queue header (U8 steps 4 and 5).
enum QueuePresentation {
    static let promptSnippetLength = 60

    /// One line of the prompt, cut to `promptSnippetLength` characters with an ellipsis when longer.
    static func snippet(_ prompt: String) -> String {
        let collapsed = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > promptSnippetLength else { return collapsed }
        return String(collapsed.prefix(promptSnippetLength)) + "…"
    }

    /// Running with a pause requested is "pausing": the current image finishes, then nothing new starts.
    static func header(isRunning: Bool, pauseRequested: Bool) -> QueueHeader {
        switch (isRunning, pauseRequested) {
        case (true, true): .pausing
        case (true, false): .running
        case (false, true): .paused
        case (false, false): .idle
        }
    }
}
