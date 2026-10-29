import Foundation
import MCCatalog
import MCEngine
import Testing

@testable import MCEngine

/// `image.cancel-recovers.<family>` for every bundled family (plan U4, R2): cancelling mid-stream ends the job, the
/// engine still answers `/health`, and the next generation on the same model completes. One engine for the suite at
/// the app's 16 GiB single-slot tier.
@Suite(.serialized, .enabled(if: ContractEnvironment.enabled))
struct ImageCancelContractTests {
    @Test func everyFamilyRecoversAfterAMidStreamCancel() async throws {
        try await ContractEngine.run(tier: ContractEngine.singleSlot) { engine in
            for target in try await ImageContract.targets(engine) {
                let family = target.family
                try await ImageContract.record(.imageCancelRecovers, for: target) { check in
                    try await ImageContract.makeResident(target, on: engine)
                    let size = try ImageContract.smallestSize(of: family)
                    let cancelled = ImageContract.request(
                        for: target, size: size, steps: ImageContract.steps(for: family), seed: 201)
                    let progressed = await Self.cancelAfterFirstProgress(cancelled, on: engine)
                    check.expect(progressed, "the generation ended before its first progress event")

                    let status = await Self.healthStatus(of: engine.endpoint, within: .seconds(30))
                    check.expect(
                        status == 200,
                        "/health answered \(status.map { String($0) } ?? "nothing") after the cancel")

                    let next = ImageContract.request(
                        for: target, size: size, steps: ImageContract.steps(for: family), seed: 202)
                    let run = try await ImageContract.generate(next, on: engine)
                    let actual = ImageContract.pngSize(run.png)
                    check.expect(
                        actual == size,
                        "the generation after the cancel returned \(ImageContract.describe(actual)) for a "
                            + "\(size.width)x\(size.height) request")
                }
            }
        }
    }

    /// Starts a generation and cancels the consuming Swift task the moment its first progress event arrives, which is
    /// the app's cancel: the stream's termination closes the connection and the engine aborts the job. Returns whether
    /// a progress event arrived at all; waits until the cancelled task has ended.
    private static func cancelAfterFirstProgress(_ request: ImageRequest, on engine: ContractEngine) async -> Bool {
        let (signals, signal) = AsyncStream<Void>.makeStream()
        let generation = Task {
            defer { signal.finish() }
            do {
                for try await event in engine.client.generateImage(request) {
                    if case .progress = event { signal.yield() }
                }
            } catch {
                // The connection closing ends the stream as an error or as a finish; either way the probe's next step
                // proves the engine survived it.
            }
        }
        var iterator = signals.makeAsyncIterator()
        let sawProgress = await iterator.next() != nil
        generation.cancel()
        await generation.value
        return sawProgress
    }

    /// Polls `/health` until it answers 200 or `timeout` passes: a cancelled job must not wedge the engine.
    private static func healthStatus(of endpoint: EngineEndpoint, within timeout: Duration) async -> Int? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var last: Int?
        while clock.now < deadline {
            if let response = try? await RawHTTP.send("GET", "health", to: endpoint, key: nil) {
                last = response.status
                if response.status == 200 { return response.status }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return last
    }
}
