// Ported from ddalcu/mlx-serve app/Sources/MLXServe/Services/ChunkedDownload.swift
// at tag v26.10.2 (commit ccedc6a), MIT License, Copyright (c) 2026 David Dalcu.
// Changed: the sidecar stores the ETag of the final post-redirect response (plan KTD6), and partials without
// a valid sidecar are discarded instead of adopted.

import Foundation

/// Per-chunk byte counts for a file in flight, kept beside its partial as `<name>.partial.parts`.
///
/// Written AFTER the bytes land, so it may under-report (those bytes are refetched at the same offsets) but never
/// over-report. It is only written once the server has answered with an ETag, so every saved sidecar carries the
/// identity of the bytes it describes.
struct ResumeSidecar: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var start: Int64
        var end: Int64 // inclusive
        var done: Int64 = 0
        var length: Int64 { end - start + 1 }
        var isComplete: Bool { done >= length }
    }

    var fileSize: Int64
    /// ETag of the final response that served this file (after any redirect). Not `X-Linked-Etag`.
    var etag: String?
    var chunks: [Entry]

    var completedBytes: Int64 { chunks.reduce(0) { $0 + $1.done } }
    var isFinished: Bool { chunks.allSatisfy { $0.isComplete } }

    /// Usable only when it describes the same size, has an ETag, and lays chunks contiguously from 0 to EOF.
    func isValid(forSize size: Int64) -> Bool {
        guard fileSize == size, size > 0, etag != nil, !chunks.isEmpty else { return false }
        var cursor: Int64 = 0
        for c in chunks {
            guard c.start == cursor, c.end >= c.start, c.done >= 0, c.done <= c.length else { return false }
            cursor = c.end + 1
        }
        return cursor == size
    }

    static func sidecarURL(forPartial partial: URL) -> URL {
        partial.appendingPathExtension("parts")
    }

    /// Loads the sidecar only if it is valid for `size` and the partial holds at least the bytes it banks.
    static func load(forPartial partial: URL, size: Int64) -> ResumeSidecar? {
        guard let data = try? Data(contentsOf: sidecarURL(forPartial: partial)),
              let state = try? JSONDecoder().decode(ResumeSidecar.self, from: data),
              state.isValid(forSize: size) else { return nil }
        // Chunks are written positionally, so the partial is at least as long as the total it banks.
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? Int64
        guard let onDisk, onDisk >= state.completedBytes else { return nil }
        return state
    }

    func save(forPartial partial: URL) throws {
        let data = try JSONEncoder().encode(self)
        // Atomic: a torn sidecar strands a multi-GB partial.
        try data.write(to: Self.sidecarURL(forPartial: partial), options: .atomic)
    }

    static func remove(forPartial partial: URL) {
        try? FileManager.default.removeItem(at: sidecarURL(forPartial: partial))
    }
}
