import Testing

@testable import MCCatalog

@Suite struct FitBandTests {
    /// The working set of the Mac the scenarios were written for.
    private let usable = 11.9

    @Test func smallNeedIsComfortable() {
        #expect(FitBand(needGB: 8, usableGB: usable) == .comfortable)
    }

    @Test func needAboveEightyFivePercentOfUsableIsTight() {
        #expect(FitBand(needGB: 10.2, usableGB: usable) == .tight)
    }

    @Test func needEqualToUsableIsTightNotExceeds() {
        #expect(FitBand(needGB: 11.9, usableGB: usable) == .tight)
    }

    @Test func needAboveUsableExceeds() {
        #expect(FitBand(needGB: 12, usableGB: usable) == .exceeds)
    }

    @Test func unknownWorkingSetGivesUnknown() {
        #expect(FitBand(needGB: 8, usableGB: nil) == .unknown)
    }

    @Test func nonPositiveWorkingSetIsTreatedAsUnknown() {
        #expect(FitBand(needGB: 8, usableGB: 0) == .unknown)
    }
}
