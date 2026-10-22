import Foundation
import MCCatalog
import MCLibrary
import MCModels

/// A shelf file that has arrived and been hash-verified, waiting in staging for the library to take it.
struct ShelfFetched: Sendable, Equatable {
    let stagedURL: URL
    let sha256: String
    let sizeBytes: Int64
}

/// Why a shelf file could not be fetched. `notFound` marks the one entry "no longer available" (AE3).
enum ShelfFetchError: Error, Equatable, LocalizedError {
    case notFound
    /// The source now lists a different file than the catalog pinned, so nothing was downloaded.
    case changed
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: "This LoRA is no longer available."
        case .changed: "The source changed this file since it was vouched for, so it was not downloaded."
        case .failed(let message): message
        }
    }
}

/// Fetches one catalog shelf entry into staging. The catalog's SHA-256 is the only thing a file must match.
protocol ShelfFetching: Sendable {
    func fetch(_ entry: LoRAShelfEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> ShelfFetched
}

/// The real fetcher: Civitai entries resolve by version id through `civitai.com` (D47) and download with the saved key
/// sent only to that host; Hugging Face entries download the pinned commit with no credentials.
struct LiveShelfFetcher: ShelfFetching {
    let client: CivitaiClient
    let civitaiDownloader: CivitaiDownloader
    let huggingFace: HuggingFaceLoRADownloader
    let keychain: any CivitaiKeyStore
    /// Shared with Civitai downloads: a staged file is moved out or swept at every open.
    let stagingDirectory: URL

    func fetch(_ entry: LoRAShelfEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> ShelfFetched {
        switch entry.source.kind {
        case .civitai: try await fetchCivitai(entry, progress: progress)
        case .huggingface: try await fetchHuggingFace(entry, progress: progress)
        }
    }

    private func fetchHuggingFace(_ entry: LoRAShelfEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> ShelfFetched {
        guard let repo = entry.source.repo, let revision = entry.source.revision, let file = entry.source.file else {
            throw ShelfFetchError.notFound
        }
        let request = HuggingFaceLoRADownloader.Request(
            repo: repo, revision: revision, file: file, sha256: entry.sha256, sizeBytes: entry.sizeBytes)
        do {
            let staged = try await huggingFace.download(request, onProgress: progress)
            return ShelfFetched(stagedURL: staged, sha256: entry.sha256, sizeBytes: entry.sizeBytes)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw ShelfFetchError.failed(error.localizedDescription)
        }
    }

    private func fetchCivitai(_ entry: LoRAShelfEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> ShelfFetched {
        guard let versionID = entry.source.versionID else { throw ShelfFetchError.notFound }
        let version: CivitaiModelVersion
        do {
            version = try await client.versionDetail(id: versionID)
        } catch CivitaiError.notFound {
            throw ShelfFetchError.notFound
        } catch {
            throw ShelfFetchError.failed(error.localizedDescription)
        }
        guard let file = version.safetensorsFile, let url = file.downloadURL, let sha256 = file.sha256, let size = file.sizeBytes else {
            throw ShelfFetchError.notFound
        }
        guard sha256 == entry.sha256.lowercased() else { throw ShelfFetchError.changed }
        let apiKey: String?
        do {
            apiKey = try keychain.read()
        } catch {
            throw ShelfFetchError.failed(error.localizedDescription)
        }
        let request = CivitaiDownloadRequest(
            versionID: versionID, downloadURL: url, apiHost: CivitaiClient.apiHost, apiKey: apiKey,
            expectedSHA256: entry.sha256.lowercased(), advertisedSize: size, classify: { _, _ in },
            stagingDirectory: stagingDirectory)
        let run = await civitaiDownloader.start(request)
        for await event in run.events {
            switch event.phase {
            case .downloading:
                if event.bytesTotal > 0 { progress(min(1, Double(event.bytesDone) / Double(event.bytesTotal))) }
            case .staged(let result):
                return ShelfFetched(stagedURL: result.stagedURL, sha256: result.sha256, sizeBytes: result.byteCount)
            case .failed(.notFound):
                throw ShelfFetchError.notFound
            case .failed(let error):
                throw ShelfFetchError.failed(error.localizedDescription)
            case .cancelled:
                throw CancellationError()
            case .preflight, .resolving, .verifying:
                break
            }
        }
        throw ShelfFetchError.failed("The download ended early.")
    }
}
