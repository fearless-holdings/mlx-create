import CryptoKit
import Foundation
import MCModels

/// A scripted Civitai API. Every request is recorded, then answered by `reply`.
actor ScriptedCivitaiAPI: CivitaiTransport {
    private(set) var requests: [URLRequest] = []
    private var reply: @Sendable (URLRequest) -> CivitaiResponse

    init(reply: @escaping @Sendable (URLRequest) -> CivitaiResponse) {
        self.reply = reply
    }

    func setReply(_ reply: @escaping @Sendable (URLRequest) -> CivitaiResponse) {
        self.reply = reply
    }

    func perform(_ request: URLRequest) async throws -> CivitaiResponse {
        requests.append(request)
        return reply(request)
    }
}

/// A scripted file host. A ranged GET gets a 206 slice with `Content-Range`; a plain GET gets the whole file with its
/// `Content-Length`. Every request is recorded. `status` answers every request with that status and no body instead.
actor ScriptedCivitaiFileHost: CivitaiFileTransport {
    private(set) var requests: [CivitaiFileRequest] = []
    private let payload: Data
    private let status: Int?

    init(payload: Data, status: Int? = nil) {
        self.payload = payload
        self.status = status
    }

    func open(_ request: CivitaiFileRequest) async throws -> CivitaiFileResponse {
        requests.append(request)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        if let status {
            continuation.finish()
            return CivitaiFileResponse(status: status, headers: [:], url: request.url, body: stream, cancel: {})
        }
        if let range = request.headers["Range"], let span = Self.span(of: range) {
            let end = min(span.end, payload.count - 1)
            continuation.yield(Data(payload[span.start...end]))
            continuation.finish()
            return CivitaiFileResponse(
                status: 206, headers: ["content-range": "bytes \(span.start)-\(end)/\(payload.count)"],
                url: request.url, body: stream, cancel: {})
        }
        continuation.yield(payload)
        continuation.finish()
        return CivitaiFileResponse(
            status: 200, headers: ["content-length": "\(payload.count)"], url: request.url, body: stream, cancel: {})
    }

    private static func span(of header: String) -> (start: Int, end: Int)? {
        let parts = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else { return nil }
        return (start, end)
    }
}

/// Counts preview fetches and returns the bytes it was given.
actor PreviewCounter {
    private(set) var calls = 0

    func fetch(_ data: Data?) -> Data? {
        calls += 1
        return data
    }
}

struct FixtureTensor {
    let name: String
    let shape: [Int]
}

/// A safetensors file: an 8-byte header length, the JSON header, then zeroed F16 data. `tag` lands in `__metadata__`, so
/// two files with the same tensors still differ in content and hash.
func safetensorsFile(_ tensors: [FixtureTensor], tag: String) throws -> Data {
    var header: [String: Any] = ["__metadata__": ["tag": tag]]
    var offset = 0
    for tensor in tensors {
        let size = tensor.shape.reduce(1, *) * 2
        header[tensor.name] = ["dtype": "F16", "shape": tensor.shape, "data_offsets": [offset, offset + size]]
        offset += size
    }
    let json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    var bytes = withUnsafeBytes(of: UInt64(json.count).littleEndian) { Data($0) }
    bytes.append(json)
    bytes.append(Data(count: offset))
    return bytes
}

/// The tensors a FLUX.2 klein 4B LoRA names: five double blocks of width 3072 (families.json).
func klein4BTensors() -> [FixtureTensor] {
    (0..<5).map { FixtureTensor(name: "double_blocks.\($0).img_attn.qkv.lora_A.weight", shape: [4, 3072]) }
}

/// The tensors a FLUX.2 klein 9B LoRA names: eight double blocks of width 4096 (families.json).
func klein9BTensors() -> [FixtureTensor] {
    (0..<8).map { FixtureTensor(name: "double_blocks.\($0).img_attn.qkv.lora_A.weight", shape: [4, 4096]) }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func civitaiResponse(_ object: Any, status: Int = 200) -> CivitaiResponse {
    CivitaiResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
}

func civitaiPage(_ items: [[String: Any]], nextCursor: String? = nil) -> [String: Any] {
    var page: [String: Any] = ["items": items]
    if let nextCursor { page["metadata"] = ["nextCursor": nextCursor] }
    return page
}

func civitaiModelJSON(
    id: Int, name: String, baseModels: [String], versions: [[String: Any]], nsfw: Bool = false
) -> [String: Any] {
    [
        "id": id, "name": name, "nsfw": nsfw, "creator": ["username": "artist"],
        "stats": ["downloadCount": 42], "baseModels": baseModels,
        "allowNoCredit": true, "allowCommercialUse": ["Image"], "allowDerivatives": true,
        "allowDifferentLicense": false, "modelVersions": versions,
    ]
}

func civitaiVersionJSON(
    id: Int, name: String, baseModel: String, publishedAt: String, trainedWords: [String] = [],
    file: [String: Any]?, imageLevel: Int = 1
) -> [String: Any] {
    [
        "id": id, "modelId": id, "name": name, "baseModel": baseModel, "publishedAt": publishedAt,
        "trainedWords": trainedWords, "files": file.map { [$0] } ?? [],
        "images": [["url": "https://image.civitai.com/x/preview.jpeg", "nsfwLevel": imageLevel, "meta": ["prompt": "a fox in snow"]]],
    ]
}

func civitaiFileJSON(url: String, sha256: String, size: Int) -> [String: Any] {
    [
        "id": 9, "name": "fox.safetensors", "sizeKB": Double(size) / 1024, "primary": true,
        "downloadUrl": url, "metadata": ["format": "SafeTensor"], "hashes": ["SHA256": sha256],
    ]
}

/// The value of one query item in a recorded request, or nil.
func queryValue(_ request: URLRequest, _ name: String) -> String? {
    queryValues(request, name).first
}

func queryValues(_ request: URLRequest, _ name: String) -> [String] {
    let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    return items.filter { $0.name == name }.compactMap(\.value)
}

/// A scripted Civitai API that holds every request while `hold()` is in effect, so a test can overlap calls.
actor GatedCivitaiAPI: CivitaiTransport {
    private(set) var requests: [URLRequest] = []
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let reply: @Sendable (URLRequest) -> CivitaiResponse

    init(reply: @escaping @Sendable (URLRequest) -> CivitaiResponse) {
        self.reply = reply
    }

    func hold() {
        holding = true
    }

    func release() {
        holding = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    func perform(_ request: URLRequest) async throws -> CivitaiResponse {
        requests.append(request)
        if holding {
            await withCheckedContinuation { waiters.append($0) }
        }
        return reply(request)
    }
}

/// A counter a `@Sendable` reply closure can advance from any thread.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// A Civitai API whose requests never answer, so a test can cancel the task that is waiting on one.
actor HangingCivitaiAPI: CivitaiTransport {
    private(set) var requests: [URLRequest] = []

    func perform(_ request: URLRequest) async throws -> CivitaiResponse {
        requests.append(request)
        try await Task.sleep(for: .seconds(60))
        return CivitaiResponse(status: 200, body: Data())
    }
}

/// Holds a preview fetch until the test releases it, and records that one has begun.
actor PreviewGate {
    private(set) var started = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func fetch(_ data: Data?) async -> Data? {
        started = true
        if !released {
            await withCheckedContinuation { waiter = $0 }
        }
        return data
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
