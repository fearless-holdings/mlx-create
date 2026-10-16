import Foundation
import MCEngine

/// Stubs the engine's HTTP routes per host (KTD9). Each test registers its own host, so suites run in parallel.
final class EngineStubProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        /// Path without the leading slash, e.g. `v1/images/generations`.
        let path: String
        let body: String
    }

    struct Reply: Sendable {
        var status: Int
        var body: Data
        /// When set, `body` is delivered and the connection stays open until `finishHeld` sends this tail.
        var tail: Data?

        static func json(_ text: String) -> Reply {
            Reply(status: 200, body: Data(text.utf8), tail: nil)
        }
    }

    typealias Handler = @Sendable (Recorded) -> Reply

    private final class HostState: @unchecked Sendable {
        let handler: Handler
        let lock = NSLock()
        var requests: [Recorded] = []
        var held: [(proto: EngineStubProtocol, tail: Data)] = []
        var closed = 0

        init(handler: @escaping Handler) { self.handler = handler }
    }

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var hosts: [String: HostState] = [:]

        func state(_ host: String) -> HostState? { lock.withLock { hosts[host] } }
        func add(_ host: String, _ state: HostState) { lock.withLock { hosts[host] = state } }
    }

    private static let registry = Registry()

    /// Registers a unique host answering with `handler`, and returns an endpoint pointing at it.
    static func register(handler: @escaping Handler) -> EngineEndpoint {
        let host = "\(UUID().uuidString.lowercased()).engine.test"
        registry.add(host, HostState(handler: handler))
        return EngineEndpoint(baseURL: URL(string: "http://\(host):9")!, apiKey: "test-key")
    }

    static func requests(_ endpoint: EngineEndpoint) -> [Recorded] {
        let s = state(endpoint)
        return s.lock.withLock { s.requests }
    }

    /// Number of connections the client closed on this host (cancelled or finished).
    static func closedCount(_ endpoint: EngineEndpoint) -> Int {
        let s = state(endpoint)
        return s.lock.withLock { s.closed }
    }

    /// Delivers the tail of every held connection on this host and completes it.
    static func finishHeld(_ endpoint: EngineEndpoint) {
        let s = state(endpoint)
        let pending = s.lock.withLock { () -> [(proto: EngineStubProtocol, tail: Data)] in
            let held = s.held
            s.held.removeAll()
            return held
        }
        for (proto, tail) in pending {
            proto.client?.urlProtocol(proto, didLoad: tail)
            proto.client?.urlProtocolDidFinishLoading(proto)
        }
    }

    private static func state(_ endpoint: EngineEndpoint) -> HostState {
        registry.state(endpoint.baseURL.host ?? "") ?? HostState(handler: { _ in Reply(status: 404, body: Data(), tail: nil) })
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return registry.state(host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// URLSession hands upload bodies to URLProtocol as a stream, so `httpBody` is usually nil.
    private static func bodyText(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let state = Self.registry.state(host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let body = Self.bodyText(of: request)
        let recorded = Recorded(
            method: request.httpMethod ?? "GET",
            path: String(url.path.dropFirst()),
            body: body
        )
        // Record the request and register any held connection under one lock, so a test that observes the
        // request can always finish the connection.
        let reply = state.lock.withLock { () -> Reply in
            state.requests.append(recorded)
            let reply = state.handler(recorded)
            if let tail = reply.tail { state.held.append((self, tail)) }
            return reply
        }
        let contentType = recorded.path.hasPrefix("v1/images") ? "text/event-stream" : "application/json"
        let response = HTTPURLResponse(
            url: url,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if reply.tail == nil {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        guard let host = request.url?.host, let state = Self.registry.state(host) else { return }
        state.lock.withLock {
            state.held.removeAll { $0.proto === self }
            state.closed += 1
        }
    }
}
