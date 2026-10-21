import Testing

@testable import MCGeneration

/// Deterministic generator so the random-policy draws are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("SeedPolicy")
struct SeedPolicyTests {
    @Test func randomDrawsVaryAcrossGenerations() {
        var rng = SplitMix64(state: 7)
        let policy = SeedPolicy.random
        let draws = (0..<32).map { policy.seed(savedCount: $0, using: &rng) }
        #expect(Set(draws).count > 1)
    }

    @Test func fixedIgnoresSavedCountAndGenerator() {
        var rng = SplitMix64(state: 1)
        let policy = SeedPolicy.fixed(12345)
        #expect(policy.seed(savedCount: 0, using: &rng) == 12345)
        #expect(policy.seed(savedCount: 9, using: &rng) == 12345)
    }

    @Test func incrementAddsSavedCount() {
        var rng = SplitMix64(state: 1)
        let policy = SeedPolicy.increment(base: 100)
        #expect(policy.seed(savedCount: 0, using: &rng) == 100)
        #expect(policy.seed(savedCount: 3, using: &rng) == 103)
    }

    @Test func incrementWrapsWithin32Bits() {
        var rng = SplitMix64(state: 1)
        let policy = SeedPolicy.increment(base: UInt32.max)
        #expect(policy.seed(savedCount: 1, using: &rng) == 0)
        #expect(policy.seed(savedCount: 2, using: &rng) == 1)
    }

    @Test func encodingRoundTrips() {
        for policy in [SeedPolicy.random, .fixed(0), .fixed(UInt32.max), .increment(base: 42)] {
            #expect(SeedPolicy(encoded: policy.encoded) == policy)
        }
    }

    @Test func invalidTextDecodesToNil() {
        #expect(SeedPolicy(encoded: "") == nil)
        #expect(SeedPolicy(encoded: "bogus") == nil)
        #expect(SeedPolicy(encoded: "fixed:") == nil)
        #expect(SeedPolicy(encoded: "fixed:abc") == nil)
        #expect(SeedPolicy(encoded: "fixed:4294967296") == nil)
        #expect(SeedPolicy(encoded: "increment:-1") == nil)
    }
}
