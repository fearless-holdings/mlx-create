import Foundation

/// Where the private engine is listening and the key it requires. The supervisor
/// publishes a new value on every (re)start; `EngineClient` reads the current one per request.
public struct EngineEndpoint: Sendable, Equatable {
    public let baseURL: URL
    public let apiKey: String

    public init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}
