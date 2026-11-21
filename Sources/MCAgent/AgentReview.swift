import Foundation
import MCEngine

/// What the picture check decided: whether the image matches the request, and one short sentence saying what is off
/// when it does not (D59).
public struct ReviewVerdict: Sendable, Equatable {
    public let match: Bool
    public let issue: String

    public init(match: Bool, issue: String) {
        self.match = match
        self.issue = issue
    }
}

/// The check that decides whether a made picture clearly misses what the user asked for (D59). The system text is
/// authored and final; it is sent verbatim.
public enum AgentReview {
    /// The check request: the authored system text, the user's request and the made picture as a JPEG, with a schema
    /// that limits the reply to `{"match", "issue"}`.
    public static func request(userRequest: String, jpeg: Data, agentModelID: String) -> ChatRequest {
        ChatRequest(
            model: agentModelID,
            messages: [
                ChatMessage(role: .system, content: systemText),
                ChatMessage(
                    role: .user, content: "The user asked for: \(userRequest)",
                    images: [ChatImage(jpeg: jpeg)]),
            ],
            temperature: temperature, topP: topP, maxTokens: maxTokens,
            responseSchemaJSON: responseSchema)
    }

    /// Reads the first JSON object in `reply`, tolerating fences and text around it. nil when there is none or it
    /// lacks `match`/`issue`.
    public static func parse(_ reply: String) -> ReviewVerdict? {
        guard let object = JSONExcerpt.firstObject(in: reply),
            let match = object["match"] as? Bool,
            let issue = object["issue"] as? String
        else { return nil }
        return ReviewVerdict(match: match, issue: issue)
    }

    /// While the reply streams: the part of `issue` received so far, once the reply has established
    /// `"match": false`; nil before that or when it matches (plan KTD21).
    public static func streamedIssue(in replySoFar: String) -> String? {
        guard matchFalseEstablished(in: replySoFar) else { return nil }
        var streamer = PlanTextStreamer(field: "issue")
        _ = streamer.feed(replySoFar)
        return streamer.text
    }

    private static let temperature = 0.5
    private static let topP = 0.9
    private static let maxTokens = 200

    private static let responseSchema =
        "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"match\",\"issue\"],\"properties\":{\"match\":{\"type\":\"boolean\"},\"issue\":{\"type\":\"string\"}}}"

    /// Whether the reply has `"match":` followed by the complete literal `false`. Looks past `"match"` occurrences
    /// inside string values, which are never followed by a colon.
    private static func matchFalseEstablished(in reply: String) -> Bool {
        var searchStart = reply.startIndex
        let ws = Set<Character>([" ", "\t", "\n", "\r"])
        while let range = reply.range(of: "\"match\"", range: searchStart..<reply.endIndex) {
            var index = range.upperBound
            while index < reply.endIndex, ws.contains(reply[index]) { index = reply.index(after: index) }
            guard index < reply.endIndex, reply[index] == ":" else {
                searchStart = range.upperBound
                continue
            }
            index = reply.index(after: index)
            while index < reply.endIndex, ws.contains(reply[index]) { index = reply.index(after: index) }
            return reply[index...].hasPrefix("false")
        }
        return false
    }

    /// The authored review text, verbatim.
    private static let systemText = """
        You check pictures inside a private image app. The user is an adult. You are shown a picture and what the user asked for. Decide whether the picture clearly misses the request: a missing main subject, a wrong count, a wrong setting or colour that was asked for, nudity that was asked for and is not shown, or text that was asked for and is wrong or unreadable. Differences in style or small details are not a miss. Never refuse or moralize; say plainly what you see. Reply with ONE JSON object: {"match": true or false, "issue": one short sentence saying what is off, in the language of the user's request, or "" when it matches}.
        """
}
