import Foundation

/// Who wrote a chat message. Named `ChatAuthor` so it does not collide with `MCEngine.ChatRole`.
public enum ChatAuthor: String, Codable, Sendable, Equatable {
    case user
    case agent
}

/// A question the agent asked, with the choices it offered and the one the user picked, if any.
public struct ChatQuestion: Codable, Equatable, Sendable {
    public var text: String
    public var suggestions: [String]
    public var chosen: String?

    public init(text: String, suggestions: [String], chosen: String? = nil) {
        self.text = text
        self.suggestions = suggestions
        self.chosen = chosen
    }
}

/// A result: the agent's sentence and the job it queued. Progress and outcome are read from the job, never stored here.
public struct ChatResult: Codable, Equatable, Sendable {
    public var text: String
    public var jobID: UUID

    public init(text: String, jobID: UUID) {
        self.text = text
        self.jobID = jobID
    }
}

/// One download an agent plan proposes: a catalog model or a shelf LoRA.
public struct ChatDownloadItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case model
        case lora
    }

    public var kind: Kind
    /// A catalog model id, or a shelf entry's SHA-256.
    public var id: String
    public var name: String
    public var sizeBytes: Int64

    public init(kind: Kind, id: String, name: String, sizeBytes: Int64) {
        self.kind = kind
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
    }
}

/// Where a proposed download stands.
public enum ChatDownloadState: Codable, Equatable, Sendable {
    case offered
    case accepted
    case finished
    case dismissed
    case failed(message: String)
}

/// The agent's download offer and what happened to it (D56).
public struct ChatDownload: Codable, Equatable, Sendable {
    public var text: String
    public var items: [ChatDownloadItem]
    public var state: ChatDownloadState
    /// The user's request to run when the download ends (R28), kept with the context a pinned send carried —
    /// the referent and the agent-only note — so the replay is the same turn the card interrupted (D59, D61).
    public var pendingRequest: String?
    public var pendingReferentImageID: UUID?
    public var pendingAgentNote: String?
    /// The first-launch setup card is the one `chatReady` may finish however its models arrived (D60); an agent's
    /// own offer finishes only after acceptance with every item in place.
    public var isSetup: Bool

    public init(
        text: String, items: [ChatDownloadItem], state: ChatDownloadState, pendingRequest: String? = nil,
        pendingReferentImageID: UUID? = nil, pendingAgentNote: String? = nil, isSetup: Bool = false
    ) {
        self.text = text
        self.items = items
        self.state = state
        self.pendingRequest = pendingRequest
        self.pendingReferentImageID = pendingReferentImageID
        self.pendingAgentNote = pendingAgentNote
        self.isSetup = isSetup
    }

    /// Rows written before `isSetup` decode as offers, the safer read: they are never finished without acceptance.
    /// Rows written before the request's context was kept replay the text alone, as they always did.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        items = try container.decode([ChatDownloadItem].self, forKey: .items)
        state = try container.decode(ChatDownloadState.self, forKey: .state)
        pendingRequest = try container.decodeIfPresent(String.self, forKey: .pendingRequest)
        pendingReferentImageID = try container.decodeIfPresent(UUID.self, forKey: .pendingReferentImageID)
        pendingAgentNote = try container.decodeIfPresent(String.self, forKey: .pendingAgentNote)
        isSetup = try container.decodeIfPresent(Bool.self, forKey: .isSetup) ?? false
    }
}

/// The D61 notice. `request` is the text Retry sends again.
public struct ChatAdultNotice: Codable, Equatable, Sendable {
    public var request: String
    public var resolved: Bool

    public init(request: String, resolved: Bool) {
        self.request = request
        self.resolved = resolved
    }
}

/// A clear miss the check found (D59). `fixRequest` is what Fix it sends; `used` is set once it was pressed.
public struct ChatMiss: Codable, Equatable, Sendable {
    public var text: String
    public var fixRequest: String
    public var used: Bool

    public init(text: String, fixRequest: String, used: Bool) {
        self.text = text
        self.fixRequest = fixRequest
        self.used = used
    }
}

/// A failed turn, with the text Try Again sends, nil when retrying cannot help.
public struct ChatFailure: Codable, Equatable, Sendable {
    public var text: String
    /// The text Try Again sends, nil when retrying cannot help.
    public var retryRequest: String?

    public init(text: String, retryRequest: String? = nil) {
        self.text = text
        self.retryRequest = retryRequest
    }
}

/// What one chat message holds (docs/lld/agent.md §8). The `kind` column stores the case name and the `body` column the
/// JSON of the payload alone, so a row a newer build wrote can be skipped instead of decoded wrongly.
public enum ChatMessageBody: Equatable, Sendable {
    case userText(String)
    case agentText(String)
    case question(ChatQuestion)
    case result(ChatResult)
    case download(ChatDownload)
    case adultNotice(ChatAdultNotice)
    case miss(ChatMiss)
    case error(ChatFailure)

    /// The `kind` column value: "userText", "agentText", "question", "result", "download", "adultNotice", "miss", "error".
    public var kind: String {
        switch self {
        case .userText: "userText"
        case .agentText: "agentText"
        case .question: "question"
        case .result: "result"
        case .download: "download"
        case .adultNotice: "adultNotice"
        case .miss: "miss"
        case .error: "error"
        }
    }

    /// The job a `.result` queued; nil for every other kind. The `job_id` column comes from this.
    var jobID: UUID? {
        if case .result(let result) = self { return result.jobID }
        return nil
    }
}

/// The payload `{"text": …}` the two plain-text kinds carry.
private struct TextPayload: Codable {
    let text: String
}

extension ChatMessageBody {
    /// The JSON text the `body` column stores: the payload alone.
    func encodedBody() throws -> String {
        let encoder = JSONEncoder()
        let data: Data
        switch self {
        case .userText(let text), .agentText(let text):
            data = try encoder.encode(TextPayload(text: text))
        case .question(let payload): data = try encoder.encode(payload)
        case .result(let payload): data = try encoder.encode(payload)
        case .download(let payload): data = try encoder.encode(payload)
        case .adultNotice(let payload): data = try encoder.encode(payload)
        case .miss(let payload): data = try encoder.encode(payload)
        case .error(let payload): data = try encoder.encode(payload)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The message a `kind`/`body` column pair describes, or nil for a kind this build does not know or a body that
    /// does not decode: such a row is skipped on read, never thrown.
    static func decode(kind: String, bodyJSON: String) -> ChatMessageBody? {
        let data = Data(bodyJSON.utf8)
        let decoder = JSONDecoder()
        do {
            switch kind {
            case "userText": return .userText(try decoder.decode(TextPayload.self, from: data).text)
            case "agentText": return .agentText(try decoder.decode(TextPayload.self, from: data).text)
            case "question": return .question(try decoder.decode(ChatQuestion.self, from: data))
            case "result": return .result(try decoder.decode(ChatResult.self, from: data))
            case "download": return .download(try decoder.decode(ChatDownload.self, from: data))
            case "adultNotice": return .adultNotice(try decoder.decode(ChatAdultNotice.self, from: data))
            case "miss": return .miss(try decoder.decode(ChatMiss.self, from: data))
            case "error": return .error(try decoder.decode(ChatFailure.self, from: data))
            default: return nil
            }
        } catch {
            return nil
        }
    }
}

/// One stored chat message (D55). `id` is the row's autoincrement, which is also the conversation's order.
public struct ChatMessageRecord: Equatable, Sendable, Identifiable {
    /// Autoincrement; the order.
    public var id: Int64
    public var collectionID: UUID
    public var author: ChatAuthor
    public var body: ChatMessageBody
    /// Set for `.result` (its job); nil otherwise.
    public var jobID: UUID?
    public var createdAt: Date

    public init(
        id: Int64, collectionID: UUID, author: ChatAuthor, body: ChatMessageBody, jobID: UUID? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.collectionID = collectionID
        self.author = author
        self.body = body
        self.jobID = jobID
        self.createdAt = createdAt
    }
}
