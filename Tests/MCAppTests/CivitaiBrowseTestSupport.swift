import Foundation
import MCCatalog
import MCLibrary
import MCModels
import Testing

@testable import MCApp

let kleinModelID = "flux-klein-4b-civitai-test"
let kleinArchitecture = "flux2-klein-4b"

func testKeychain() -> CivitaiKeychain {
    CivitaiKeychain(service: "test-civitai-\(UUID().uuidString)")
}

/// A harness with one selected FLUX.2 klein 4B model, a scripted Civitai API and file host.
@MainActor
func browseHarness(
    api: any CivitaiTransport,
    files: ScriptedCivitaiFileHost? = nil,
    keychain: any CivitaiKeyStore,
    preview: (@Sendable (URL) async -> Data?)? = nil,
    models: [(id: String, architecture: String)] = [(kleinModelID, kleinArchitecture)],
    selected: String? = kleinModelID
) async throws -> AppHarness {
    let harness = try await AppHarness.make(
        models: models, civitaiTransport: api, civitaiFileTransport: files, civitaiKeychain: keychain,
        civitaiPreviewFetch: preview ?? { _ in nil })
    await harness.model.start()
    await harness.model.refreshModels()
    harness.model.selectedModelID = selected
    return harness
}

func searchReply(_ items: [[String: Any]], cursor: String? = nil) -> @Sendable (URLRequest) -> CivitaiResponse {
    let body = (try? JSONSerialization.data(withJSONObject: civitaiPage(items, nextCursor: cursor))) ?? Data()
    return { _ in CivitaiResponse(status: 200, body: body) }
}

/// A FLUX.2 klein 4B LoRA listing whose one version downloads `payload` from `downloadURL`.
func foxListing(id: Int, versionID: Int, payload: Data, name: String = "Watercolor Fox") -> [String: Any] {
    let file = civitaiFileJSON(
        url: "https://civitai.com/api/download/models/\(versionID)", sha256: sha256Hex(payload), size: payload.count)
    let version = civitaiVersionJSON(
        id: versionID, name: "v1", baseModel: "Flux.2 Klein 4B", publishedAt: "2026-02-01T00:00:00.000Z",
        trainedWords: ["wcfox", "watercolor"], file: file)
    return civitaiModelJSON(id: id, name: name, baseModels: ["Flux.2 Klein 4B"], versions: [version])
}

/// A FLUX.2 klein 4B LoRA listing with a placeholder file, for tests about the search rows only.
func kleinListing(id: Int, nsfw: Bool = false) -> [String: Any] {
    let version = civitaiVersionJSON(
        id: id * 10, name: "v1", baseModel: "Flux.2 Klein 4B", publishedAt: "2026-02-01T00:00:00.000Z",
        file: civitaiFileJSON(url: "https://civitai.com/api/download/models/\(id * 10)", sha256: "00", size: 1))
    return civitaiModelJSON(
        id: id, name: "Klein \(id)", baseModels: ["Flux.2 Klein 4B"], versions: [version], nsfw: nsfw)
}

/// A FLUX.2 klein 4B LoRA listing whose one file carries `sha256` as its hash.
func listingWithHash(id: Int, sha256: String, size: Int) -> [String: Any] {
    let version = civitaiVersionJSON(
        id: id * 10, name: "v1", baseModel: "Flux.2 Klein 4B", publishedAt: "2026-02-01T00:00:00.000Z",
        file: civitaiFileJSON(url: "https://civitai.com/api/download/models/\(id * 10)", sha256: sha256, size: size))
    return civitaiModelJSON(id: id, name: "Hash \(id)", baseModels: ["Flux.2 Klein 4B"], versions: [version])
}

/// Page one lists `first` and points at cursor `c2`; the request for `c2` gets `second` and no further cursor.
func twoPages(_ first: [[String: Any]], _ second: [[String: Any]]) -> @Sendable (URLRequest) -> CivitaiResponse {
    let firstBody = (try? JSONSerialization.data(withJSONObject: civitaiPage(first, nextCursor: "c2"))) ?? Data()
    let secondBody = (try? JSONSerialization.data(withJSONObject: civitaiPage(second))) ?? Data()
    return { request in
        CivitaiResponse(status: 200, body: queryValue(request, "cursor") == "c2" ? secondBody : firstBody)
    }
}

/// A Keychain whose every call fails, to check that a read error is shown and never sends a keyless download.
struct FailingKeyStore: CivitaiKeyStore {
    struct Locked: LocalizedError {
        var errorDescription: String? { "The Keychain is locked." }
    }

    func read() throws -> String? { throw Locked() }
    func write(_ key: String) throws { throw Locked() }
}
