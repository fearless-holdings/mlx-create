import Foundation

/// Where the Civitai key may travel and which plain-http hosts are tolerated (plan KTD2).
///
/// The key is sent only to `apiHost`, and only over a URL this policy accepts. Production passes no plain-http hosts,
/// so every non-https URL is refused. Tests name loopback hosts to reach the local fixture server over http; every
/// other host stays https-only.
public struct CivitaiTransportPolicy: Sendable, Equatable {
    /// The only host that receives `Authorization`, lowercase.
    public let apiHost: String
    /// Hosts, lowercase, that may be reached over plain http. Empty in production.
    public let plaintextHosts: Set<String>

    public init(apiHost: String, plaintextHosts: Set<String> = []) {
        self.apiHost = apiHost.lowercased()
        self.plaintextHosts = Set(plaintextHosts.map { $0.lowercased() })
    }

    /// Whether a URL may be requested at all: https, or plain http to a host named in `plaintextHosts`.
    public func accepts(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return plaintextHosts.contains(host)
        default: return false
        }
    }

    /// Whether the key may be sent with a request for `url`.
    public func sendsKey(to url: URL) -> Bool {
        accepts(url) && url.host?.lowercased() == apiHost
    }

    public enum Redirect: Sendable, Equatable {
        /// Follow the hop. `keepKey` is true only when the hop stays on the host that already holds the key.
        case follow(keepKey: Bool)
        /// Do not follow. The 3xx response is returned to the caller instead.
        case refuse(reason: String)
    }

    /// Decides one redirect hop. `carriesKey` says whether the hop being left sent the key.
    ///
    /// - A target this policy does not accept is refused.
    /// - A same-host hop that would step down to plain http while carrying the key is refused. The API would be
    ///   steering the key onto the wire in the clear, so the request fails instead of continuing.
    /// - A cross-host hop is followed with the key dropped, so the key never reaches a host other than the one it was
    ///   issued for.
    public func redirect(from current: URL, to target: URL, carriesKey: Bool) -> Redirect {
        guard accepts(target) else {
            return .refuse(reason: "the server redirected to an address that is not https")
        }
        let sameHost = current.host?.lowercased() == target.host?.lowercased()
        if sameHost && carriesKey && target.scheme?.lowercased() != "https" {
            return .refuse(reason: "the server redirected the key-bearing request to plain http")
        }
        return .follow(keepKey: sameHost && carriesKey)
    }
}

/// One GET for the downloader. Headers are sent as given. The policy governs redirects.
public struct CivitaiFileRequest: Sendable {
    public let url: URL
    public let headers: [String: String]
    public let policy: CivitaiTransportPolicy

    public init(url: URL, headers: [String: String], policy: CivitaiTransportPolicy) {
        self.url = url
        self.headers = headers
        self.policy = policy
    }
}

/// The head of a response and its body. The body streams after `open` returns; `cancel` stops the transfer and is safe
/// to call once the body has finished.
public struct CivitaiFileResponse: Sendable {
    public let status: Int
    /// Header names, lowercased.
    public let headers: [String: String]
    /// The URL that answered, after any followed redirects.
    public let url: URL
    public let body: AsyncThrowingStream<Data, any Error>
    public let cancel: @Sendable () -> Void

    public init(
        status: Int,
        headers: [String: String],
        url: URL,
        body: AsyncThrowingStream<Data, any Error>,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.status = status
        self.headers = headers
        self.url = url
        self.body = body
        self.cancel = cancel
    }
}

/// What the Civitai downloader needs from the network (D30 pattern). Tests and production share the same interface.
public protocol CivitaiFileTransport: Sendable {
    /// Starts one GET and returns when the response head arrives. Redirects are decided by the request's policy.
    func open(_ request: CivitaiFileRequest) async throws -> CivitaiFileResponse
}

/// Production transport: an ephemeral URLSession with cookies off. No hop is followed unless the policy allows it.
public struct URLSessionCivitaiFileTransport: CivitaiFileTransport {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    public func open(_ request: CivitaiFileRequest) async throws -> CivitaiFileResponse {
        var urlRequest = URLRequest(url: request.url)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (body, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        let sink = CivitaiFileSink(policy: request.policy, body: continuation)
        let task = session.dataTask(with: urlRequest)
        task.delegate = sink
        continuation.onTermination = { _ in task.cancel() }
        let head = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (resume: CheckedContinuation<CivitaiHead, Error>) in
                // Set before `resume()`, so no callback can beat it.
                sink.awaitHead(resume)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return CivitaiFileResponse(
            status: head.status,
            headers: head.headers,
            url: head.url,
            body: body,
            cancel: { task.cancel() })
    }
}

private struct CivitaiHead: Sendable {
    let status: Int
    let headers: [String: String]
    let url: URL
}

/// Receives one response. Redirects go through the policy, the head resolves `open`, and the body feeds the stream.
private final class CivitaiFileSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let policy: CivitaiTransportPolicy
    private let body: AsyncThrowingStream<Data, any Error>.Continuation
    private let lock = NSLock()
    private var head: CheckedContinuation<CivitaiHead, Error>?

    init(policy: CivitaiTransportPolicy, body: AsyncThrowingStream<Data, any Error>.Continuation) {
        self.policy = policy
        self.body = body
        super.init()
    }

    func awaitHead(_ continuation: CheckedContinuation<CivitaiHead, Error>) {
        lock.withLock { head = continuation }
    }

    private func settleHead(_ result: Result<CivitaiHead, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<CivitaiHead, Error>? in
            let continuation = head
            head = nil
            return continuation
        }
        pending?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let from = task.currentRequest?.url ?? response.url, let to = request.url else {
            completionHandler(nil)
            return
        }
        let carriesKey = task.currentRequest?.value(forHTTPHeaderField: "Authorization") != nil
        switch policy.redirect(from: from, to: to, carriesKey: carriesKey) {
        case .follow(let keepKey):
            var next = request
            if !keepKey {
                next.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            completionHandler(next)
        case .refuse:
            // The 3xx response is delivered as the final response, and the caller reports it.
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let url = dataTask.currentRequest?.url ?? http.url else {
            settleHead(.failure(CivitaiDownloadError.network(reason: "the response was not HTTP")))
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        settleHead(.success(CivitaiHead(status: http.statusCode, headers: headers, url: url)))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            settleHead(.failure(error))
            body.finish(throwing: error)
        } else {
            settleHead(.failure(CivitaiDownloadError.network(reason: "the server closed the connection before answering")))
            body.finish()
        }
    }
}
