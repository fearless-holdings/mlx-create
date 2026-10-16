import Foundation
import Testing
@testable import MCEngine

@Suite struct EngineLaunchTests {
    private let home = URL(fileURLWithPath: "/tmp/AppSupport/Engine")
    private let modelDir = URL(fileURLWithPath: "/tmp/Models/Weights")
    private let tmp = URL(fileURLWithPath: "/tmp/usertmp/")
    private let secret = "SECRET-KEY-DO-NOT-LEAK-0123456789abcdef"

    private func args(tier: MemoryTier = MemoryTier(physicalMemoryBytes: 24 << 30)) -> [String] {
        EngineLaunch.arguments(port: 53117, modelDir: modelDir, tier: tier)
    }

    /// Each `--flag` mapped to the value that follows it. Flags without a value map to "".
    private func flags(_ argv: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for (index, argument) in argv.enumerated() where argument.hasPrefix("--") {
            let next = index + 1
            let hasValue = next < argv.count && !argv[next].hasPrefix("--")
            result[argument] = hasValue ? argv[next] : ""
        }
        return result
    }

    @Test func bindsLoopbackOnlyAndNeverPassesLANFlags() {
        let argv = args()
        #expect(flags(argv)["--host"] == "127.0.0.1")
        #expect(!argv.contains { $0.hasPrefix("--lan") })
    }

    @Test func keyIsReadFromEnvironmentWithStrictAuth() {
        let argv = args()
        #expect(flags(argv)["--api-key-env"] == "MLXC_ENGINE_KEY")
        #expect(flags(argv)["--api-key-strict"] != nil)
    }

    @Test func portAndModelDirArePassedAsFlagValues() {
        let argv = args()
        #expect(flags(argv)["--port"] == "53117")
        #expect(flags(argv)["--model-dir"] == modelDir.path)
    }

    @Test func residentModelLimitFollowsTheMemoryTier() {
        let sixteen = flags(args(tier: MemoryTier(physicalMemoryBytes: 16 << 30)))
        #expect(sixteen["--max-resident-models"] == "1")
        let large = flags(args(tier: MemoryTier(physicalMemoryBytes: 64 << 30)))
        #expect(large["--max-resident-models"] == "3")
    }

    @Test func environmentIsBuiltFromExactlyFourVariables() {
        let env = EngineLaunch.environment(home: home, apiKey: secret, temporaryDirectory: tmp)
        #expect(Set(env.keys) == ["HOME", "MLXC_ENGINE_KEY", "PATH", "TMPDIR"])
        #expect(env["HOME"] == home.path)
        #expect(env["MLXC_ENGINE_KEY"] == secret)
        #expect(env["TMPDIR"] == tmp.path)
        // PATH holds only the system directories; nothing is inherited from the app's environment.
        let entries = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(!entries.isEmpty && entries.allSatisfy { ["/usr/bin", "/bin"].contains($0) })
    }

    @Test func generatedKeysAreBase64URLWithoutPadding() {
        let key = EngineLaunch.makeAPIKey()
        #expect(key.count == 43) // 32 bytes, base64url, unpadded
        #expect(!key.contains("+") && !key.contains("/") && !key.contains("="))
    }

    @Test func everyLaunchGetsAFreshKey() {
        #expect(EngineLaunch.makeAPIKey() != EngineLaunch.makeAPIKey())
    }
}
