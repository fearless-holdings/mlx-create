// Ported from ddalcu/mlx-serve app/Sources/MLXServe/Services/ChunkedDownload.swift
// at tag v26.10.2 (commit ccedc6a), MIT License, Copyright (c) 2026 David Dalcu.

import Foundation

/// Byte-range planning for multi-connection downloads (ported from upstream `DownloadChunking`).
enum Chunking {
    struct Chunk: Equatable {
        var start: Int64
        var end: Int64  // inclusive
        var length: Int64 { end - start + 1 }
    }

    static let maxConnections = 16

    /// Splits `fileSize` into at most `connections` contiguous chunks of at least `minChunkBytes` each.
    /// An empty result means one stream: unknown size, too small to split, or one connection.
    static func plan(fileSize: Int64, connections: Int, minChunkBytes: Int64) -> [Chunk] {
        guard fileSize > 0, minChunkBytes > 0 else { return [] }
        let affordable = max(fileSize / minChunkBytes, 1)
        let count = Int(min(Int64(min(max(connections, 1), maxConnections)), affordable))
        guard count > 1 else { return [] }

        let base = fileSize / Int64(count)
        var out: [Chunk] = []
        var start: Int64 = 0
        for i in 0..<count {
            // The last chunk absorbs the remainder, so the plan always ends exactly at EOF.
            let end = (i == count - 1) ? fileSize - 1 : start + base - 1
            out.append(Chunk(start: start, end: end))
            start = end + 1
        }
        return out
    }
}
