import Foundation
import Testing

@testable import MCEngine

@Suite("SSE line parsing")
struct SSEParsingTests {
    @Test("a progress line yields progress with step, total and stage")
    func progress() {
        let line = #"data: {"type":"progress","stage":"denoise","step":2,"total":8}"#
        #expect(SSELineParser.parse(line: line) == .event(.progress(step: 2, total: 8, stage: "denoise")))
    }

    @Test("a preview field is ignored, yielding the same progress")
    func previewIgnored() {
        let with = #"data: {"type":"progress","stage":"denoise","step":2,"total":8,"preview":"iVBORw0KGgo="}"#
        let without = #"data: {"type":"progress","stage":"denoise","step":2,"total":8}"#
        #expect(SSELineParser.parse(line: with) == SSELineParser.parse(line: without))
    }

    @Test("a progress event with total missing has no fraction and does not divide by zero")
    func missingTotalFraction() {
        let line = #"data: {"type":"progress","stage":"denoise","step":3}"#
        let parsed = SSELineParser.parse(line: line)
        #expect(parsed == .event(.progress(step: 3, total: 0, stage: "denoise")))
        if case .event(let event) = parsed {
            #expect(event.fraction == nil)
        }
    }

    @Test("a progress event with total 0 has no fraction")
    func zeroTotalFraction() {
        #expect(GenEvent.progress(step: 1, total: 0, stage: "").fraction == nil)
        #expect(GenEvent.progress(step: 1, total: 4, stage: "").fraction == 0.25)
    }

    @Test("a complete line decodes the base64 PNG")
    func complete() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let line = #"data: {"type":"complete","data":[{"b64_json":"\#(png.base64EncodedString())"}]}"#
        #expect(SSELineParser.parse(line: line) == .event(.completed(png: png)))
    }

    @Test("an error event maps its type and message")
    func errorEvent() {
        let line = #"data: {"type":"error","error":{"type":"out_of_memory","message":"low memory"}}"#
        #expect(SSELineParser.parse(line: line) == .failed(.outOfMemory(engineMessage: "low memory")))
    }

    @Test("an error event without a type is an engine failure carrying its message")
    func untypedErrorEvent() {
        let line = #"data: {"type":"error","message":"boom"}"#
        #expect(SSELineParser.parse(line: line) == .failed(.engineFailure(type: nil, engineMessage: "boom")))
    }

    @Test("blank lines, comments, DONE and unknown event types are ignored")
    func ignored() {
        #expect(SSELineParser.parse(line: "") == .ignored)
        #expect(SSELineParser.parse(line: ": keep-alive") == .ignored)
        #expect(SSELineParser.parse(line: "data: [DONE]") == .ignored)
        #expect(SSELineParser.parse(line: #"data: {"type":"something_new"}"#) == .ignored)
    }

    @Test("a data line that is not JSON is malformed")
    func malformed() {
        if case .failed(.malformedResponse) = SSELineParser.parse(line: "data: {not json") {
        } else {
            Issue.record("expected a malformed-response failure")
        }
    }
}
