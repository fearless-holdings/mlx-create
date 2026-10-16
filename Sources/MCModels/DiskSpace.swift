import Foundation

/// Free-space reading for the install preflight (plan KTD8).
public enum DiskSpace {
    /// Bytes available for important usage on the volume holding `url`. `url` must exist.
    public static func availableForImportantUsage(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            throw InstallError.staging(reason: "the volume's free space is unavailable")
        }
        return bytes
    }
}
