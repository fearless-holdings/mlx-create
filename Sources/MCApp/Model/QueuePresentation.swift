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

    /// Calibration never overlaps a job, so a running job keeps its header. Otherwise calibration takes precedence over
    /// idle and paused, and the queue's own state returns when it ends.
    static func header(isRunning: Bool, pauseRequested: Bool, isCalibrating: Bool = false) -> QueueHeader {
        if isCalibrating, !isRunning { return .calibrating }
        return header(isRunning: isRunning, pauseRequested: pauseRequested)
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
