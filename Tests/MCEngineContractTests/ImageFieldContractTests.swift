import Foundation
import MCCatalog
import MCEngine
import Testing

@testable import MCEngine

/// The image field probes (plan U4, R2): `image.dimensions`, `image.size-clamp`, `image.default-steps`,
/// `image.seed-determinism` and `image.composed-request` for every bundled family. One engine for the suite at the
/// app's 16 GiB single-slot tier. Every size, step count and capability comes from the family record. The engine runs
/// with `EngineLaunch.environment`, so Qwen-Image renders under `MLX_SERVE_QWEN_IMAGE_LOW_MEMORY=1` as it does in the app.
@Suite(.serialized, .enabled(if: ContractEnvironment.enabled))
struct ImageFieldContractTests {
    @Test func everyFamilyMatchesItsRecordedGeometryStepsSeedAndComposition() async throws {
        try await ContractEngine.run(tier: ContractEngine.singleSlot) { engine in
            let registry = try ContractModels.registry()
            for target in try await ImageContract.targets(engine) {
                let family = target.family
                let size = try ImageContract.smallestSize(of: family)

                try await ImageContract.record(.imageDimensions, for: target) { check in
                    try await ImageContract.makeResident(target, on: engine)
                    let request = ImageContract.request(
                        for: target, size: size, steps: ImageContract.steps(for: family), seed: 101)
                    let run = try await ImageContract.generate(request, on: engine)
                    let actual = ImageContract.pngSize(run.png)
                    check.expect(
                        actual == size,
                        "the PNG is \(ImageContract.describe(actual)) and the request was \(size.width)x\(size.height)")
                }

                try await ImageContract.record(.imageSizeClamp, for: target) { check in
                    try await ImageContract.makeResident(target, on: engine)
                    let grid = family.sizeGrid
                    let unaligned = ImageSize(width: size.width + 1, height: size.height + grid.multiple / 2 + 1)
                    let expected = registry.normalize(unaligned, for: family)
                    check.expect(
                        unaligned != expected,
                        "the probe's request \(ImageContract.describe(unaligned)) is already on the grid")
                    let request = ImageContract.request(
                        for: target, size: unaligned, steps: ImageContract.steps(for: family), seed: 102)
                    let run = try await ImageContract.generate(request, on: engine)
                    let actual = ImageContract.pngSize(run.png)
                    check.expect(
                        actual == expected,
                        "the PNG is \(ImageContract.describe(actual)) and the record's clamp of "
                            + "\(ImageContract.describe(unaligned)) is \(ImageContract.describe(expected))")
                }

                try await ImageContract.record(.imageDefaultSteps, for: target) { check in
                    try await ImageContract.makeResident(target, on: engine)
                    let request = ImageContract.request(for: target, size: size, steps: nil, seed: 103)
                    let run = try await ImageContract.generate(request, on: engine)
                    let totals = Set(ImageContract.progress(run.events).map { $0.total })
                    check.expect(!totals.isEmpty, "no progress event arrived")
                    check.expect(
                        totals == [family.steps.defaultSteps],
                        "the stream ran \(totals.sorted()) steps and the record's default is \(family.steps.defaultSteps)")
                }

                try await ImageContract.record(.imageSeedDeterminism, for: target) { check in
                    try await ImageContract.makeResident(target, on: engine)
                    let seed: UInt32 = 104
                    let steps = ImageContract.steps(for: family)
                    let first = try await ImageContract.generate(
                        ImageContract.request(for: target, size: size, steps: steps, seed: seed), on: engine)
                    let again = try await ImageContract.generate(
                        ImageContract.request(for: target, size: size, steps: steps, seed: seed), on: engine)
                    check.expect(
                        first.png == again.png, "two requests with seed \(seed) returned different bytes")
                    let other = try await ImageContract.generate(
                        ImageContract.request(for: target, size: size, steps: steps, seed: seed &+ 1), on: engine)
                    check.expect(
                        other.png != first.png, "seed \(seed &+ 1) returned the bytes of seed \(seed)")
                }

                try await ImageContract.record(.imageComposedRequest, for: target) { check in
                    try await ImageContract.makeResident(target, on: engine)
                    let request = ImageContract.request(
                        for: target, size: size, steps: ImageContract.steps(for: family), seed: 105)
                    let body = try request.body()
                    guard let wire = (try JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                        check.expect(false, "the composed request is not a JSON object")
                        return
                    }
                    // Every shipped record has guidance nil and no negative prompt; a record that gains either field
                    // makes the probe send it, because that is what `GenerationComposer` would then compose.
                    check.expect(
                        request.guidance == family.guidance?.defaultValue,
                        "the request carries guidance \(String(describing: request.guidance)) and the record says "
                            + "\(String(describing: family.guidance?.defaultValue))")
                    if let guidance = family.guidance {
                        check.expect(
                            (wire["guidance_scale"] as? Double) == guidance.defaultValue,
                            "the wire body carries guidance_scale \(String(describing: wire["guidance_scale"])) "
                                + "and the record says \(guidance.defaultValue)")
                    } else {
                        check.expect(
                            wire["guidance_scale"] == nil,
                            "the record has no guidance and the wire body carries guidance_scale")
                    }
                    if family.supportsNegativePrompt {
                        check.expect(
                            request.negativePrompt == ImageContract.composedNegativePrompt,
                            "the request carries no negative prompt on a family that supports one")
                        check.expect(
                            (wire["negative_prompt"] as? String) == ImageContract.composedNegativePrompt,
                            "the wire body's negative_prompt is \(String(describing: wire["negative_prompt"]))")
                    } else {
                        check.expect(
                            request.negativePrompt == nil,
                            "the record supports no negative prompt and the request carries one")
                        check.expect(
                            wire["negative_prompt"] == nil,
                            "the record supports no negative prompt and the wire body carries negative_prompt")
                    }
                    let run = try await ImageContract.generate(request, on: engine)
                    let actual = ImageContract.pngSize(run.png)
                    check.expect(
                        actual == size,
                        "the engine's PNG is \(ImageContract.describe(actual)) and the composed request was "
                            + "\(size.width)x\(size.height)")
                }
            }
        }
    }
}
