// Ported from ddalcu/mlx-serve app/Sources/MLXServe/Services/ChunkedDownload.swift
// at tag v26.10.2 (commit ccedc6a), MIT License, Copyright (c) 2026 David Dalcu.

import Darwin
import Foundation

/// A file opened for positional writes. `pwrite` carries its own offset, so N chunk connections can fill their own
/// regions of one partial concurrently with no seek races.
final class PositionalFile: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    /// Opens an existing file for writing, or creates it. Pass `truncate` to start from empty.
    init(url: URL, truncate: Bool) throws {
        let flags = O_WRONLY | O_CREAT | (truncate ? O_TRUNC : 0)
        let opened = open(url.path, flags, 0o644)
        guard opened >= 0 else { throw Self.posixError() }
        fd = opened
    }

    func write(_ data: Data, at offset: Int64) throws {
        var cursor = offset
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var ptr = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = pwrite(fd, ptr, remaining, off_t(cursor))
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError()
                }
                guard written > 0 else { throw Self.posixError(EIO) }
                remaining -= written
                ptr = ptr.advanced(by: written)
                cursor += Int64(written)
            }
        }
    }

    func truncate(to length: Int64) throws {
        guard ftruncate(fd, off_t(length)) == 0 else { throw Self.posixError() }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = Darwin.close(fd)
    }

    deinit { close() }

    static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }
}
