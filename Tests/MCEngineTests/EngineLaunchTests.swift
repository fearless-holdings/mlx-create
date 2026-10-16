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

    @Test func bindsLoopbackOnlyAndNeverPassesLANFlags() {
        let a = args()
        #expect(a.contains("--host"))
        #expect(a[a.firstIndex(of: "--host")! + 1] == "127.0.0.1")
        #expect(!a.contains { $0.hasPrefix("--lan") })
    }

    @Test func keyIsReadFromEnvironmentWithStrictAuth() {
        let a = args()
        #expect(a[a.firstIndex(of: "--api-key-env")! + 1] == "MLXC_ENGINE_KEY")
        #expect(a.contains("--api-key-strict"))
    }

    @Test func argvNeverContainsAKeyValue() {
        // The builder takes no key at all; the key only ever travels in the environment.
        #expect(!args().contains(secret))
    }

    @Test func portAndModelDirAreTheOnlyPaths() {
        let a = args()
        #expect(a[a.firstIndex(of: "--port")! + 1] == "53117")
        #expect(a[a.firstIndex(of: "--model-dir")! + 1] == "/tmp/Models/Weights")
    }

    @Test func residentModelLimitFollowsTheMemoryTier() {
        let sixteen = args(tier: MemoryTier(physicalMemoryBytes: 16 << 30))
        #expect(sixteen[sixteen.firstIndex(of: "--max-resident-models")! + 1] == "1")
        let large = args(tier: MemoryTier(physicalMemoryBytes: 64 << 30))
        #expect(large[large.firstIndex(of: "--max-resident-models")! + 1] == "3")
    }

    @Test func environmentIsBuiltFromExactlyFourVariables() {
        let env = EngineLaunch.environment(home: home, apiKey: secret, temporaryDirectory: tmp)
        #expect(Set(env.keys) == ["HOME", "MLXC_ENGINE_KEY", "PATH", "TMPDIR"])
        #expect(env["HOME"] == home.path)
        #expect(env["MLXC_ENGINE_KEY"] == secret)
        #expect(env["PATH"] == "/usr/bin:/bin")
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
