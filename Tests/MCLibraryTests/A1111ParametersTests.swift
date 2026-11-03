import Testing

@testable import MCLibrary

@Suite struct A1111ParametersTests {
    @Test func unclosedLoRATagsKeepTheTextAndFinishQuickly() {
        let hostile = String(repeating: "<lora:x ", count: 20_000)
        let started = SuspendingClock.now
        let parsed = A1111Parameters.parse("\(hostile)\nSteps: 20")
        #expect(parsed?.steps == 20)
        #expect(parsed?.loras.isEmpty == true)
        #expect(SuspendingClock.now - started < .seconds(5))
    }

    @Test func plainTextParsesEveryField() {
        let text = """
            a cat
            Negative prompt: blurry
            Steps: 20, Sampler: Euler, CFG scale: 7, Seed: 123, Size: 512x768, Model hash: abc123, Model: someName, Lora hashes: "nameA: 1a2b3c4d5e, nameB: 9f8e7d6c5b", Civitai resources: [{"type":"checkpoint","modelVersionId":1}]
            """
        #expect(
            A1111Parameters.parse(text)
                == ImageGenerationData(
                    source: .a1111,
                    prompt: "a cat",
                    negativePrompt: "blurry",
                    steps: 20,
                    guidance: 7,
                    seed: 123,
                    width: 512,
                    height: 768,
                    modelName: "someName",
                    loras: [
                        .init(name: "nameA", hash: "1a2b3c4d5e"),
                        .init(name: "nameB", hash: "9f8e7d6c5b"),
                    ]
                ))
    }

    @Test func multiLinePromptAndNegativeKeepTheirLines() {
        let text = """
            line one
            line two: detail
            Negative prompt: bad hands,
            blurry
            worst quality
            Steps: 30, CFG scale: 4.5, Seed: 9, Size: 640x480, Model: m1
            """
        #expect(
            A1111Parameters.parse(text)
                == ImageGenerationData(
                    source: .a1111,
                    prompt: "line one\nline two: detail",
                    negativePrompt: "bad hands,\nblurry\nworst quality",
                    steps: 30,
                    guidance: 4.5,
                    seed: 9,
                    width: 640,
                    height: 480,
                    modelName: "m1"
                ))
    }

    @Test func quotedLoRAHashesKeepColonsAndCommasInsideTheQuotes() {
        let text =
            "p\nSteps: 20, Lora hashes: \"style: noir: 1a2b3c4d5e, detail: 9f8e7d6c5b\", Model: x"
        #expect(
            A1111Parameters.parse(text)
                == ImageGenerationData(
                    source: .a1111,
                    prompt: "p",
                    steps: 20,
                    modelName: "x",
                    loras: [
                        .init(name: "style: noir", hash: "1a2b3c4d5e"),
                        .init(name: "detail", hash: "9f8e7d6c5b"),
                    ]
                ))
    }

    @Test func loraTagsAreStrippedAndWeightsPairByNameIgnoringCase() {
        let text =
            "a <lora:Detail:0.8> cat, <lora:style:-0.5:extra> neon\n"
            + "Negative prompt: <lora:detail:0.3> blurry\n"
            + "Steps: 20, Lora hashes: \"Detail: aaaaaaaaaa, STYLE: bbbbbbbbbb\""
        #expect(
            A1111Parameters.parse(text)
                == ImageGenerationData(
                    source: .a1111,
                    prompt: "a cat, neon",
                    negativePrompt: "<lora:detail:0.3> blurry",
                    steps: 20,
                    loras: [
                        .init(name: "Detail", hash: "aaaaaaaaaa", weight: 0.8),
                        .init(name: "STYLE", hash: "bbbbbbbbbb", weight: -0.5),
                    ]
                ))
    }

    @Test func tagWithoutAHashEntryYieldsAnEmptyHashReference() {
        let text =
            "p <lora:orphan:0.6>, <lora:Detail:0.9>\n"
            + "Steps: 20, Lora hashes: \"Detail: aaaaaaaaaa\""
        #expect(
            A1111Parameters.parse(text)
                == ImageGenerationData(
                    source: .a1111,
                    prompt: "p",
                    steps: 20,
                    loras: [
                        .init(name: "Detail", hash: "aaaaaaaaaa", weight: 0.9),
                        .init(name: "orphan", hash: "", weight: 0.6),
                    ]
                ))
    }

    @Test func civitaiResourcesWithCommasDoNotBreakLaterFields() {
        let text =
            "a cat\n"
            + "Steps: 20, Civitai resources: [{\"type\":\"checkpoint\",\"modelVersionId\":1},{\"type\":\"lora\",\"weight\":0.5}], Seed: 77, Size: 512x512, Model: mm"
        #expect(
            A1111Parameters.parse(text)
                == ImageGenerationData(
                    source: .a1111,
                    prompt: "a cat",
                    steps: 20,
                    seed: 77,
                    width: 512,
                    height: 512,
                    modelName: "mm"
                ))
    }

    @Test func negativeAndLargeSeedsAreKeptVerbatim() {
        #expect(A1111Parameters.parse("x\nSteps: 20, Seed: -1")?.seed == -1)
        #expect(A1111Parameters.parse("x\nSeed: 4294967296, Steps: 20")?.seed == 4_294_967_296)
    }

    @Test func textWithNoSettingsLineAndNoNegativePromptReturnsNil() {
        #expect(A1111Parameters.parse("just a prompt\nno settings here") == nil)
        #expect(A1111Parameters.parse("") == nil)
    }

    @Test func negativePromptWithoutSettingsLineParsesPromptAndNegativeOnly() {
        let text = "a cat\nNegative prompt: blurry\nmore words"
        #expect(
            A1111Parameters.parse(text)
                == ImageGenerationData(
                    source: .a1111,
                    prompt: "a cat",
                    negativePrompt: "blurry\nmore words"
                ))
    }

    @Test func ourWriterShapeWithoutStepsParses() {
        let text =
            "CFG scale: 4.0, Seed: 7, Size: 1024x1024, Model: a/b, Lora hashes: \"Grain: 0123456789\""
        #expect(
            A1111Parameters.parse(text)
                == ImageGenerationData(
                    source: .a1111,
                    prompt: "",
                    guidance: 4.0,
                    seed: 7,
                    width: 1024,
                    height: 1024,
                    modelName: "a/b",
                    loras: [.init(name: "Grain", hash: "0123456789")]
                ))
    }

    @Test func ourWriterLineWithLoRAsParsesBackToNamesAndHashes() {
        let text =
            "a cat\nNegative prompt: blurry\n"
            + "Steps: 8, CFG scale: 3.5, Seed: 4000000000, Size: 1024x768, Model: ddalcu/Krea-2-Turbo, "
            + "Lora hashes: \"detail_ tweaker: ab12cd34ef, style_ noir: 9f8e7d6c5b\""
        #expect(
            A1111Parameters.parse(text)
                == ImageGenerationData(
                    source: .a1111,
                    prompt: "a cat",
                    negativePrompt: "blurry",
                    steps: 8,
                    guidance: 3.5,
                    seed: 4_000_000_000,
                    width: 1024,
                    height: 768,
                    modelName: "ddalcu/Krea-2-Turbo",
                    loras: [
                        .init(name: "detail_ tweaker", hash: "ab12cd34ef"),
                        .init(name: "style_ noir", hash: "9f8e7d6c5b"),
                    ]
                ))
    }

    @Test func malformedSettingsValuesLeaveFieldsNilWithoutCrashing() {
        let text =
            "Steps: abc, Size: 512, Seed: 1.5, CFG scale: nan, Model: , Lora hashes: \"novalue, : 12\""
        #expect(A1111Parameters.parse(text) == ImageGenerationData(source: .a1111, prompt: ""))
    }

    @Test func malformedTagsStayInThePrompt() {
        let text = "a <lora:> b <lora:n:abc> c\nSteps: 1"
        #expect(
            A1111Parameters.parse(text)
                == ImageGenerationData(
                    source: .a1111,
                    prompt: "a <lora:> b <lora:n:abc> c",
                    steps: 1
                ))
    }

    @Test func samplerAloneIsEnoughForASettingsLine() {
        #expect(
            A1111Parameters.parse("p\nSampler: Euler a")
                == ImageGenerationData(source: .a1111, prompt: "p"))
    }

    @Test func crlfLineEndingsParse() {
        let text = "a cat\r\nNegative prompt: x\r\nSteps: 20\r\n"
        #expect(
            A1111Parameters.parse(text)
                == ImageGenerationData(
                    source: .a1111,
                    prompt: "a cat",
                    negativePrompt: "x",
                    steps: 20
                ))
    }
}
