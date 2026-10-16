import Foundation

/// Allowlist of file types the app will ever write into a model folder (AGENTS non-negotiable 6,
/// plan KTD21). Shared by the catalog loader, the catalog tool and the downloader so they cannot drift.
/// Pickle-based formats execute code on load, so anything not listed here is rejected.
public enum WeightFilePolicy {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case rejected(reason: String)
    }

    private static let allowedExtensions: Set<String> = ["safetensors", "json"]
    private static let allowedNames: Set<String> = ["chat_template.jinja", "LICENSE", "NOTICE"]

    /// - Parameter relativePath: a path relative to the model folder, `/`-separated.
    public static func check(_ relativePath: String) -> Verdict {
        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        if allowedNames.contains(name) { return .allowed }
        let ext = (name as NSString).pathExtension.lowercased()
        if allowedExtensions.contains(ext) { return .allowed }
        return .rejected(
            reason:
                "\(name) is not an allowed model file type (only .safetensors, .json, chat_template.jinja, LICENSE and NOTICE)"
        )
    }
}
