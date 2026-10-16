import Foundation
import Testing
@testable import MCEngine

@Suite struct ModelsSymlinkTests {
    private let fm = FileManager.default

    /// Temp layout: `<root>/Weights` (target) and `<root>/engine/.mlx-serve/models` (link).
    private func makeLayout(weights: Bool = true) throws -> (root: URL, link: URL, target: URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        let target = root.appendingPathComponent("Weights")
        let link = root.appendingPathComponent("engine/.mlx-serve/models")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if weights { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
        return (root, link, target)
    }

    private func destination(of link: URL) throws -> String? {
        let attrs = try fm.attributesOfItem(atPath: link.path)
        guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { return nil }
        return try fm.destinationOfSymbolicLink(atPath: link.path)
    }

    @Test func absentLinkIsCreatedAtTheWeightsFolder() throws {
        let (root, link, target) = try makeLayout()
        defer { try? fm.removeItem(at: root) }
        try ModelsSymlink.reconcile(link: link, target: target)
        #expect(try destination(of: link) == target.path)
    }

    @Test func correctLinkIsLeftAlone() throws {
        let (root, link, target) = try makeLayout()
        defer { try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        try ModelsSymlink.reconcile(link: link, target: target)
        #expect(try destination(of: link) == target.path)
    }

    @Test func linkElsewhereIsReplacedWithoutLeavingATempLinkBehind() throws {
        let (root, link, target) = try makeLayout()
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("OldWeights")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: old.path)
        try ModelsSymlink.reconcile(link: link, target: target)
        #expect(try destination(of: link) == target.path)
        let leftovers = try fm.contentsOfDirectory(atPath: link.deletingLastPathComponent().path)
        #expect(leftovers == ["models"])
    }

    @Test func realDirectoryIsNeverDeleted() throws {
        let (root, link, target) = try makeLayout()
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: link, withIntermediateDirectories: true)
        let userFile = link.appendingPathComponent("user-data.txt")
        try Data("keep".utf8).write(to: userFile)

        #expect(throws: EngineSetupError.self) {
            try ModelsSymlink.reconcile(link: link, target: target)
        }
        #expect(fm.fileExists(atPath: userFile.path))
    }

    @Test func realFileIsNeverDeleted() throws {
        let (root, link, target) = try makeLayout()
        defer { try? fm.removeItem(at: root) }
        try Data("keep".utf8).write(to: link)

        #expect(throws: EngineSetupError.self) {
            try ModelsSymlink.reconcile(link: link, target: target)
        }
        #expect(try Data(contentsOf: link) == Data("keep".utf8))
    }

    @Test func missingWeightsFolderFailsAndLeavesTheLinkAlone() throws {
        let (root, link, target) = try makeLayout(weights: false)
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("OldWeights")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: old.path)

        #expect(throws: EngineSetupError.self) {
            try ModelsSymlink.reconcile(link: link, target: target)
        }
        #expect(try destination(of: link) == old.path)
    }
}
