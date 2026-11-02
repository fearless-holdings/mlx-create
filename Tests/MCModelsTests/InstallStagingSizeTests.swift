import Foundation
import Testing

@testable import MCModels

/// A fresh directory for one test, removed afterwards.
private func makeStagingDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "staging-size-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

struct InstallStagingSizeTests {
    /// A partial written by ranged parts is sparse: its logical size is the final size, its allocated size is what
    /// arrived. The reported size follows the bytes written, not the file's apparent size.
    @Test func aSparsePartialCountsOnlyTheBytesWritten() throws {
        let directory = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "weights.safetensors.partial")

        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 1, count: 1024 * 1024))

        let size = InstallStaging.directorySize(directory)
        #expect(size >= 1024 * 1024)
        #expect(size < 8 * 1024 * 1024)
    }

    @Test func aFullyWrittenFileReportsItsLogicalSize() throws {
        let directory = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "config.json")
        let contents = Data(repeating: 7, count: 3001)
        try contents.write(to: file)

        #expect(InstallStaging.directorySize(directory) == Int64(contents.count))
    }

    @Test func emptyAndMissingDirectoriesReportNothing() throws {
        let directory = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(InstallStaging.directorySize(directory) == 0)

        let missing = directory.appending(path: "absent", directoryHint: .isDirectory)
        #expect(InstallStaging.directorySize(missing) == 0)
    }
}
