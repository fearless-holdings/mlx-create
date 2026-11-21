import Foundation
import Testing

@testable import MCAgent

@Suite("PlanTextStreamer")
struct PlanTextStreamerTests {
    @Test func wholeReplyInOneDelta() {
        var streamer = PlanTextStreamer()
        let reply = #"{"intent":"make a fox","text":"Making a fox.","action":"generate","model":"m1"}"#
        #expect(streamer.feed(reply) == "Making a fox.")
        #expect(streamer.text == "Making a fox.")
    }

    @Test func oneCharacterPerDelta() {
        var streamer = PlanTextStreamer()
        let reply = #"{"intent":"x","text":"Hi there","action":"say"}"#
        var collected = ""
        for scalar in reply.unicodeScalars {
            collected += streamer.feed(String(scalar))
        }
        #expect(collected == "Hi there")
        #expect(streamer.text == "Hi there")
    }

    @Test func escapesSplitAcrossDeltas() {
        // A "\n" escape cut after the backslash, and a "\u00e9" cut inside its hex digits.
        var streamer = PlanTextStreamer()
        let parts = [#"{"text":"a\"#, #"n b\u0"#, #"0e9 c"#, #"","action":"say"}"#]
        var collected = ""
        for part in parts { collected += streamer.feed(part) }
        #expect(collected == "a\n bé c")
        #expect(streamer.text == "a\n bé c")
    }

    @Test func everyEscapeKindDecodes() {
        var streamer = PlanTextStreamer()
        let reply = #"{"text":"a\tb\rc\bd\fe\/f\"g\\h"}"#
        #expect(streamer.feed(reply) == "a\tb\rc\u{8}d\u{c}e/f\"g\\h")
    }

    @Test func surrogatePairSplitAcrossDeltas() {
        // U+1F603 (a smiling face) = D83D DE03, delivered one delta at a time.
        var streamer = PlanTextStreamer()
        let reply = #"{"text":"hi 😃 bye"}"#
        var collected = ""
        for index in reply.unicodeScalars.indices {
            let delta = String(reply.unicodeScalars[index])
            collected += streamer.feed(delta)
        }
        #expect(collected == "hi 😃 bye")
    }

    @Test func absentFieldEmitsNothing() {
        var streamer = PlanTextStreamer()
        let reply = #"{"intent":"x","other":"not it","action":"say"}"#
        #expect(streamer.feed(reply) == "")
        #expect(streamer.text == "")
    }

    @Test func fieldAfterOtherFields() {
        var streamer = PlanTextStreamer(field: "issue")
        let reply = #"{"match":false,"issue":"wrong count"}"#
        #expect(streamer.feed(reply) == "wrong count")
    }

    @Test func nestedSameNamedKeysAreIgnored() {
        var streamer = PlanTextStreamer()
        let reply = #"{"data":{"text":"nested"},"list":[{"text":"deep"}],"action":"say"}"#
        #expect(streamer.feed(reply) == "")
        #expect(streamer.text == "")
    }

    @Test func fencedReply() {
        var streamer = PlanTextStreamer()
        let reply = "```json\n{\"intent\":\"x\",\"text\":\"Inside.\",\"action\":\"say\"}\n```"
        #expect(streamer.feed(reply) == "Inside.")
    }

    @Test func nothingEmittedAfterClosingQuote() {
        var streamer = PlanTextStreamer()
        #expect(streamer.feed(#"{"text":"done"#) == "done")
        #expect(streamer.feed(#"","text":"again"}"#) == "")
        #expect(streamer.text == "done")
    }

    @Test func nonStringFieldValueEmitsNothing() {
        var streamer = PlanTextStreamer()
        #expect(streamer.feed(#"{"text":5,"action":"say"}"#) == "")
        #expect(streamer.feed(#"{"text":{"text":"inner"},"action":"say"}"#) == "")
    }

    @Test func partialValueReturnsWhatArrived() {
        var streamer = PlanTextStreamer()
        #expect(streamer.feed(#"{"int"#) == "")
        #expect(streamer.feed(#"ent":"x","text":"Mak"#) == "Mak")
        #expect(streamer.feed("ing") == "ing")
        #expect(streamer.text == "Making")
    }
}
