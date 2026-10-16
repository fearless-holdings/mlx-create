import Foundation

/// How many models the engine keeps resident, chosen from unified-memory size (LLD §5.2, HLD §11).
public struct MemoryTier: Sendable, Equatable {
    public let maxResidentModels: Int

    public init(physicalMemoryBytes: UInt64) {
        let gib: UInt64 = 1 << 30
        switch physicalMemoryBytes {
        case ..<(24 * gib): maxResidentModels = 1
        case ..<(48 * gib): maxResidentModels = 2
        default: maxResidentModels = 3
        }
    }

    public static var current: MemoryTier {
        MemoryTier(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }
}
