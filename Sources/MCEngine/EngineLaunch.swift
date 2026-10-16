import Foundation
import Security

/// Builds the engine's argv and environment (LLD §5.2). The key never appears in argv.
public enum EngineLaunch {
    public static let keyEnvironmentName = "MLXC_ENGINE_KEY"

    public static func arguments(port: Int, modelDir: URL, tier: MemoryTier) -> [String] {
        [
            "--serve",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--api-key-env", keyEnvironmentName,
            "--api-key-strict",
            "--model-dir", modelDir.path,
            "--max-resident-mem", "auto",
            "--max-resident-models", String(tier.maxResidentModels),
            "--log-level", "info",
        ]
    }

    /// Built from exactly these four variables; nothing is inherited from the app's environment.
    public static func environment(home: URL, apiKey: String, temporaryDirectory: URL) -> [String: String] {
        [
            "HOME": home.path,
            keyEnvironmentName: apiKey,
            "PATH": "/usr/bin:/bin",
            "TMPDIR": temporaryDirectory.path,
        ]
    }

    /// 32 bytes from SecRandomCopyBytes, base64url, unpadded. Regenerated on every launch.
    public static func makeAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
