import Foundation

// Civitai's public API client (HLD §8.7, KTD2). Requests go only to `https://civitai.com/api/v1`. The optional saved key
// travels as an Authorization header on requests to that host over https, and nowhere else.

/// The status and body of one Civitai response.
public struct CivitaiResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The network seam for Civitai requests (D30 pattern). The app uses `URLSessionCivitaiTransport`; tests script replies.
public protocol CivitaiTransport: Sendable {
    /// Sends one request. Throws only when no response arrived. HTTP error statuses come back as responses.
    func perform(_ request: URLRequest) async throws -> CivitaiResponse
}

/// Production transport: an ephemeral session with cookies off, no cache, and a fixed User-Agent.
public struct URLSessionCivitaiTransport: CivitaiTransport {
    private let session: URLSession

    public init(userAgent: String) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.timeoutIntervalForRequest = 30
        session = URLSession(
            configuration: config,
            delegate: CivitaiRedirectGuard(policy: CivitaiTransportPolicy(apiHost: CivitaiClient.apiHost)),
            delegateQueue: nil)
    }

    public func perform(_ request: URLRequest) async throws -> CivitaiResponse {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CivitaiError.malformedResponse }
        return CivitaiResponse(status: http.statusCode, body: body)
    }
}

/// Keeps the API session on the API host. A redirect that leaves `civitai.com`, or is not https, is refused: the 3xx
/// response is returned rather than followed keyless. Key handling on a same-host hop is the policy's rule.
final class CivitaiRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: CivitaiTransportPolicy

    init(policy: CivitaiTransportPolicy) {
        self.policy = policy
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let carriesKey = task.currentRequest?.value(forHTTPHeaderField: "Authorization") != nil
        guard let from = task.currentRequest?.url ?? response.url, let to = request.url,
              case .follow(let keepKey) = policy.redirect(from: from, to: to, carriesKey: carriesKey),
              to.host?.lowercased() == policy.apiHost
        else {
            completionHandler(nil)
            return
        }
        var next = request
        if !keepKey {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}

/// Failures the Civitai client reports. `errorDescription` is plain language for the UI.
public enum CivitaiError: Error, Sendable, Equatable, LocalizedError {
    /// 401 or 403 when no key was sent: Civitai wants one. `message` is Civitai's own text when it sent one.
    case needsKey(message: String?)
    /// 401 or 403 when the saved key was sent: Civitai refused it.
    case keyRefused
    /// 404: no such model or version.
    case notFound
    /// 429: too many requests.
    case rateLimited
    /// 451: this region is not served these results. No live region-limited response has been recorded yet.
    case regionLimited
    /// Any other non-2xx status.
    case httpStatus(Int)
    /// No response arrived: offline, DNS, TLS or timeout.
    case network
    /// A 2xx body the client cannot read.
    case malformedResponse
    /// A request the client refuses to build, such as a hash that is not 64 hex digits.
    case invalidRequest

    public var errorDescription: String? {
        switch self {
        case .needsKey:
            return "This LoRA needs a Civitai key. Add your key and try again."
        case .keyRefused:
            return "Civitai refused your saved API key. Replace it in the Civitai key field and try again."
        case .notFound:
            return "Civitai no longer lists this LoRA."
        case .rateLimited:
            return "Civitai is limiting requests right now. Wait a minute and try again."
        case .regionLimited:
            return "Civitai limits results in your region."
        case .httpStatus(let status):
            return "Civitai returned an error (HTTP \(status)). Try again later."
        case .network:
            return "Couldn't reach Civitai. Check your internet connection and try again."
        case .malformedResponse:
            return "Civitai sent a response this version of the app can't read."
        case .invalidRequest:
            return "That request can't be made."
        }
    }
}

/// Civitai's `sort` values for the Browse tab.
public enum CivitaiSort: String, CaseIterable, Sendable {
    case mostDownloaded = "Most Downloaded"
    case highestRated = "Highest Rated"
    case newest = "Newest"
}

/// Civitai's public LoRA API: search, version detail and lookup by file hash (HLD §8.7). Anonymous unless a key is saved.
public actor CivitaiClient {
    /// The API host. Only this host, over https on the default port, may receive the key.
    public static let apiHost = "civitai.com"
    /// `https://civitai.com/api/v1`, built from ``apiHost``.
    public static let apiBase = URL(string: "https://\(apiHost)/api/v1")!
    static let pageSize = 20
    private static let policy = CivitaiTransportPolicy(apiHost: apiHost)

    private let transport: any CivitaiTransport
    private let savedKey: @Sendable () -> String?

    /// - Parameter savedKey: Read on every request, so a key saved after the client exists applies to the next request.
    public init(transport: any CivitaiTransport, savedKey: @escaping @Sendable () -> String? = { nil }) {
        self.transport = transport
        self.savedKey = savedKey
    }

    /// Searches LoRAs. `baseModelLabels` filters to Civitai's base-model labels; an empty list applies no label filter.
    /// `includeNSFW` sends Civitai's `nsfw` flag, so false excludes NSFW results (R7).
    public func search(
        query: String?,
        sort: CivitaiSort,
        baseModelLabels: [String],
        includeNSFW: Bool,
        cursor: String?
    ) async throws -> CivitaiSearchPage {
        var items = [
            URLQueryItem(name: "types", value: "LORA"),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "nsfw", value: includeNSFW ? "true" : "false"),
        ]
        if let term = query?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty {
            items.append(URLQueryItem(name: "query", value: term))
        }
        items += baseModelLabels.map { URLQueryItem(name: "baseModels", value: $0) }
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await get(Self.apiBase.appending(path: "models"), query: items, as: CivitaiSearchPage.self)
    }

    /// One version with its files, images and trigger words.
    public func versionDetail(id: Int) async throws -> CivitaiModelVersion {
        let url = Self.apiBase.appending(path: "model-versions").appending(path: String(id))
        return try await get(url, query: [], as: CivitaiModelVersion.self)
    }

    /// The version whose file has this SHA-256, or nil when Civitai has no such file.
    public func versionByHash(sha256: String) async throws -> CivitaiModelVersion? {
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { throw CivitaiError.invalidRequest }
        let url = Self.apiBase
            .appending(path: "model-versions")
            .appending(path: "by-hash")
            .appending(path: sha256.uppercased())
        do {
            return try await get(url, query: [], as: CivitaiModelVersion.self)
        } catch CivitaiError.notFound {
            return nil
        }
    }

    // MARK: Requests

    private func get<T: Decodable & Sendable>(_ base: URL, query: [URLQueryItem], as type: T.Type) async throws -> T {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw CivitaiError.invalidRequest
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw CivitaiError.invalidRequest }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var keySent = false
        if let key = savedKey(), !key.isEmpty, Self.policy.sendsKey(to: url) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            keySent = true
        }

        let response: CivitaiResponse
        do {
            response = try await transport.perform(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as CivitaiError {
            throw error
        } catch {
            throw CivitaiError.network
        }
        return try Self.decode(response, as: type, keySent: keySent)
    }

    private static func decode<T: Decodable>(_ response: CivitaiResponse, as type: T.Type, keySent: Bool) throws -> T {
        switch response.status {
        case 200..<300:
            do {
                return try JSONDecoder().decode(type, from: response.body)
            } catch {
                throw CivitaiError.malformedResponse
            }
        case 401, 403:
            if keySent { throw CivitaiError.keyRefused }
            throw CivitaiError.needsKey(message: errorMessage(response.body))
        case 404:
            throw CivitaiError.notFound
        case 429:
            throw CivitaiError.rateLimited
        case 451:
            throw CivitaiError.regionLimited
        default:
            throw CivitaiError.httpStatus(response.status)
        }
    }

    private static func errorMessage(_ body: Data) -> String? {
        struct ErrorBody: Decodable {
            let message: String?
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: body))?.message
    }
}
