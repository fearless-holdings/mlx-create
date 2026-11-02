import Foundation
import Testing

@testable import MCApp

/// Time left for a download, from the byte counts it reported (Swift Testing, no real clock).
@Suite struct InstallRateEstimatorTests {
    private static let megabyte: Int64 = 1_000_000

    private static func seconds(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value)
    }

    @Test func oneSampleGivesNoEstimate() {
        var rate = InstallRateEstimator()
        rate.record(bytes: 0, at: Self.seconds(0))

        #expect(rate.secondsLeft(total: 1_100 * Self.megabyte) == nil)
    }

    @Test func aSpanUnderFiveSecondsGivesNoEstimate() {
        var rate = InstallRateEstimator()
        rate.record(bytes: 0, at: Self.seconds(0))
        rate.record(bytes: 10 * Self.megabyte, at: Self.seconds(4))

        #expect(rate.secondsLeft(total: 1_100 * Self.megabyte) == nil)
    }

    @Test func aHundredMegabytesInTenSecondsWithAThousandLeftReportsAboutAHundredSeconds() throws {
        var rate = InstallRateEstimator()
        rate.record(bytes: 0, at: Self.seconds(0))
        rate.record(bytes: 100 * Self.megabyte, at: Self.seconds(10))

        let secondsLeft = try #require(rate.secondsLeft(total: 1_100 * Self.megabyte))
        #expect(abs(secondsLeft - 100) <= 1)
    }

    @Test func aByteCountThatGoesDownClearsTheSamples() {
        var rate = InstallRateEstimator()
        rate.record(bytes: 0, at: Self.seconds(0))
        rate.record(bytes: 100 * Self.megabyte, at: Self.seconds(10))
        rate.record(bytes: 1, at: Self.seconds(11))

        #expect(rate.samples.count == 1)
        #expect(rate.secondsLeft(total: 1_100 * Self.megabyte) == nil)
    }

    @Test func eachMagnitudeOfTimeLeftReadsDifferently() {
        let texts = [30, 600, 7200].map { InstallRateEstimator.text(secondsLeft: Double($0)) }

        #expect(Set(texts).count == texts.count)
    }
}
