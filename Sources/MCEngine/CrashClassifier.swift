// Adapted from upstream ddalcu/mlx-serve app/Sources/MLXServe/Services/ServerManager.swift
// (summarizeCrash, isRequestPreviewLine, isMemoryFailure) at commit ccedc6a, MIT License.
// Deviation: preview lines are excluded before every match, including the preflight and OOM checks.
import Foundation

public enum ExitStatus: Sendable, Equatable {
    case code(Int32)
    case signal(Int32)
}

public enum EnginePhase: Sendable, Equatable {
    case setup
    case launching
    case ready
}

public enum CrashKind: Sendable, Equatable, CaseIterable {
    case outOfMemory
    case killedBySystem
    case missingWeights
    case launchFailed
    case setupFailed
    case unknown

    /// Whether the in-flight job may be retried (LLD §5.6).
    public var jobRetryable: Bool {
        switch self {
        case .outOfMemory: OutOfMemoryFailure.retryable
        case .killedBySystem, .unknown: true
        case .missingWeights, .launchFailed, .setupFailed: false
        }
    }
}

public enum CrashClassifier {
    static let preflightMarker = "Insufficient memory to load model"

    public static func classify(logTail: String, exit: ExitStatus, phase: EnginePhase) -> CrashKind {
        if phase == .setup { return .setupFailed }
        let lines = conversationFreeLines(logTail)
        if lines.contains(where: { $0.contains("MISSING WEIGHT") }) { return .missingWeights }
        if lines.contains(where: isMemoryFailure) { return .outOfMemory }
        if phase == .launching { return .launchFailed }
        if case .signal(9) = exit { return .killedBySystem }
        return .unknown
    }

    /// One-line diagnostic for the user and logs. Never returns a request preview line.
    public static func summarize(_ log: String, exit: ExitStatus) -> String {
        let fallback: String
        switch exit {
        case .code(let n): fallback = "exit code \(n)"
        case .signal(let n): fallback = "terminated by signal \(n)"
        }
        let lines = conversationFreeLines(log)
        if lines.isEmpty { return fallback }
        if let line = lines.last(where: { $0.contains(preflightMarker) }) { return line }
        if lines.contains(where: isMemoryFailure) {
            return "Out of GPU memory while loading the model — free memory (close other models/apps) and try again."
        }
        let needles = ["terminating due to", "MLX error", "MISSING WEIGHT", "[fatal]", "panic", "error:"]
        for line in lines.reversed() where needles.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
            if let r = line.range(of: "std::runtime_error: ") {
                return String(line[r.upperBound...])
            }
            return line
        }
        return lines.last ?? fallback
    }

    /// A `> "…"` line echoes conversation text into the log; its content can match any needle without being the cause.
    public static func isRequestPreviewLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("> \"")
    }

    static func isMemoryFailure(_ line: String) -> Bool {
        if line.contains(preflightMarker) { return true }
        return line.contains("kIOGPUCommandBufferCallbackErrorOutOfMemory")
            || (line.contains("[METAL]") && line.localizedCaseInsensitiveContains("Insufficient Memory"))
    }

    /// Lines with request echoes removed. An echo can span several lines when its first 80 bytes hold a newline; the
    /// engine closes the echo with `"` at the end of its last line, so everything in between is dropped. 80 bytes hold at
    /// most 80 newlines, so an echo that never closes stops swallowing lines after that, and a real error behind it stays.
    private static func conversationFreeLines(_ log: String) -> [String] {
        let maxEchoLines = 81
        var kept: [String] = []
        var echoLinesLeft = 0
        for line in log.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).map(String.init) {
            if echoLinesLeft > 0 {
                echoLinesLeft = line.hasSuffix("\"") ? 0 : echoLinesLeft - 1
                continue
            }
            guard isRequestPreviewLine(line) else {
                kept.append(line)
                continue
            }
            // The opening `> "` is three bytes; the echo is closed on this line only if a quote follows it.
            let body = line.trimmingCharacters(in: .whitespaces).dropFirst(3)
            echoLinesLeft = (body.hasSuffix("\"") && !body.isEmpty) ? 0 : maxEchoLines
        }
        return kept
    }
}
