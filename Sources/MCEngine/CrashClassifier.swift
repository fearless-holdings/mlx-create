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

public enum CrashKind: Sendable, Equatable {
    case outOfMemory
    case killedBySystem
    case missingWeights
    case launchFailed
    case setupFailed
    case unknown

    /// Whether the in-flight job may be retried (LLD §5.6).
    public var jobRetryable: Bool {
        switch self {
        case .outOfMemory, .killedBySystem, .unknown: true
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

    private static func conversationFreeLines(_ log: String) -> [String] {
        log.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !isRequestPreviewLine($0) }
    }
}
