import Testing

@testable import MCEngine

@Suite struct MemoryTierTests {
    private let gib: UInt64 = 1 << 30

    @Test func sixteenGigabyteMacKeepsOneModelResident() {
        #expect(MemoryTier(physicalMemoryBytes: 16 * gib).maxResidentModels == 1)
    }

    @Test func twentyFourAndThirtyTwoGigabyteMacsKeepTwoResident() {
        #expect(MemoryTier(physicalMemoryBytes: 24 * gib).maxResidentModels == 2)
        #expect(MemoryTier(physicalMemoryBytes: 32 * gib).maxResidentModels == 2)
    }

    @Test func fortyEightGigabyteAndUpKeepThreeResident() {
        #expect(MemoryTier(physicalMemoryBytes: 48 * gib).maxResidentModels == 3)
        #expect(MemoryTier(physicalMemoryBytes: 128 * gib).maxResidentModels == 3)
    }
}
